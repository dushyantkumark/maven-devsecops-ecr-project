def COLOR_MAP = [
    'SUCCESS': 'good',
    'FAILURE': 'danger',
]

pipeline {
    agent any
    tools {
        maven 'MAVEN3'
        jdk 'JDK17'
    }
    environment {

        SCANNER_HOME = tool 'sonar-scanner'

        ARTVERSION = "${env.BUILD_ID}"

        // DOCKER_NAME  = 'harishnshetty/vprofile'
        registryCredential = 'ecr:ap-south-1:awscreds'
        IMAGE_NAME   = '970378220457.dkr.ecr.ap-south-1.amazonaws.com/vprofileappimg'               
        vprofileRegistry = "https://970378220457.dkr.ecr.ap-south-1.amazonaws.com"
    }
    
    stages {
        stage("Clean Workspace") {
            steps {
                cleanWs()
            }
        }

        stage("Git Checkout") {
            steps {
                git branch: 'main', url: 'https://github.com/harishnshetty/maven-devsecops-ecr-project.git'
            }
        }

        stage('BUILD') {
            steps {
                sh 'mvn clean install -DskipTests'
            }
            post {
                success {
                    echo 'Now Archiving...'
                    archiveArtifacts artifacts: '**/target/*.war'
                }
            }
        }

        stage('UNIT TEST') {
            steps {
                sh 'mvn test'
            }
        }

        stage('INTEGRATION TEST') {
            steps {
                sh 'mvn verify -DskipUnitTests'
            }
        }
        
        stage('CODE ANALYSIS WITH CHECKSTYLE') {
            steps {
                sh 'mvn checkstyle:checkstyle'
            }
            post {
                success {
                    echo 'Generated Analysis Result'
                }
            }
        }

        stage('CODE ANALYSIS with SONARQUBE') {
            steps {
                withSonarQubeEnv('sonar-server') {
                    sh '''${SCANNER_HOME}/bin/sonar-scanner -Dsonar.projectKey=vprofile \
                        -Dsonar.projectName=vprofile-repo \
                        -Dsonar.projectVersion=1.0 \
                        -Dsonar.sources=src/ \
                        -Dsonar.java.binaries=target/test-classes/com/visualpathit/account/controllerTest/ \
                        -Dsonar.junit.reportsPath=target/surefire-reports/ \
                        -Dsonar.jacoco.reportsPath=target/jacoco.exec \
                        -Dsonar.java.checkstyle.reportPaths=target/checkstyle-result.xml'''
                }
                
            }
        }
        stage("Quality Gate") {
            steps {
                script {
                    timeout(time: 3, unit: 'MINUTES') {
                  
                    waitForQualityGate abortPipeline: false, credentialsId: 'sonar-token'
                }
            }
        }
        }

        

        stage("OWASP Dependency Check Scan") {
            steps {
                dependencyCheck additionalArguments: '''
                    --scan . 
                    --disableYarnAudit 
                    --disableNodeAudit 
                ''',
                odcInstallation: 'dp-check'
                dependencyCheckPublisher pattern: '**/dependency-check-report.xml'
            }
        }

        stage("Trivy File Scan") {
            steps {
                sh "trivy fs . > trivyfs.txt"
            }
        }

        stage("Build Docker Image") {
            steps {
                script {
                    env.IMAGE_TAG = "${IMAGE_NAME}:${BUILD_NUMBER}"
                    sh "docker rmi -f ${IMAGE_NAME}:latest ${env.IMAGE_TAG} || true"
                    
                    // Build and capture the docker image object
                    dockerImage = docker.build("${IMAGE_NAME}:latest", ".")
                    
                    // Tag with build number
                    sh "docker tag ${IMAGE_NAME}:latest ${env.IMAGE_TAG}"
                }
            }
        }

        stage("Trivy Scan Image") {
            steps {
                script {
                    sh """
                    echo '🔍 Running Trivy scan on ${env.IMAGE_TAG}'
                    trivy image -f json -o trivy-image.json ${env.IMAGE_TAG}
                    trivy image -f table -o trivy-image.txt ${env.IMAGE_TAG}
                    """
                }
            }
        }
        

        stage("Upload App Image to ECR") {
            steps {
                script {
                    docker.withRegistry( vprofileRegistry, registryCredential ) {
                        dockerImage.push("${BUILD_NUMBER}")
                        dockerImage.push("latest")
                    }
                }
            }
        }

        stage("Deploy to Container") {
            steps {
                script {
                    sh "docker rm -f vprofile || true"
                    sh "docker run -d --name vprofile -p 80:8080 ${env.IMAGE_TAG}"
                }
            }
        }

        stage("DAST Scan with OWASP ZAP") {
            steps {
                script {
                    echo '🔍 Running OWASP ZAP baseline scan...'

                    // Run ZAP but ignore exit code
                    def exitCode = sh(script: '''
                        docker run --rm --user root --network host -v $(pwd):/zap/wrk:rw \
                        -t zaproxy/zap-stable zap-baseline.py \
                        -t http://localhost \
                        -r zap_report.html -J zap_report.json
                    ''', returnStatus: true)

                    echo "ZAP scan finished with exit code: ${exitCode}"

                    // Read the JSON report if it exists
                    if (fileExists('zap_report.json')) {
                        def zapJson = readJSON file: 'zap_report.json'

                        def highCount = zapJson.site.collect { site ->
                            site.alerts.findAll { it.risk == 'High' }.size()
                        }.sum()

                        def mediumCount = zapJson.site.collect { site ->
                            site.alerts.findAll { it.risk == 'Medium' }.size()
                        }.sum()

                        def lowCount = zapJson.site.collect { site ->
                            site.alerts.findAll { it.risk == 'Low' }.size()
                        }.sum()

                        echo "✅ High severity issues: ${highCount}"
                        echo "⚠️ Medium severity issues: ${mediumCount}"
                        echo "ℹ️ Low severity issues: ${lowCount}"
                    } else {
                        echo "ZAP JSON report not found, continuing build..."
                    }
                }
            }
            post {
                always {
                    echo '📦 Archiving ZAP scan reports...'
                    archiveArtifacts artifacts: 'zap_report.html,zap_report.json', allowEmptyArchive: true
                }
            }
        }


    }
    
