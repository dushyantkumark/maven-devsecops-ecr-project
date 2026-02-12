pipeline {
    agent any

    tools {
        maven 'MAVEN3'
        jdk 'JDK17'
    }

    parameters {
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Optional custom image tag')
        booleanParam(name: 'SKIP_DAST', defaultValue: false, description: 'Skip OWASP ZAP Scan')
    }

    environment {
        SCANNER_HOME = tool 'sonar-scanner'
        IMAGE_REPO   = "profilemappimg"
    }

    stages {

        stage("Clean Workspace") {
            steps {
                cleanWs()
            }
        }

        stage("Checkout Code") {
            steps {
                git branch: 'devsecops',
                    url: 'https://github.com/dushyantkumark/maven-devsecops-ecr-project.git'
            }
        }

        stage("Build Application") {
            steps {
                sh 'mvn clean install -DskipTests'
            }
        }

        stage("SonarQube Analysis") {
            steps {
                withSonarQubeEnv('sonar-server') {
                    sh """
                        ${SCANNER_HOME}/bin/sonar-scanner \
                        -Dsonar.projectKey=vprofile \
                        -Dsonar.sources=src \
                        -Dsonar.java.binaries=target/classes
                    """
                }
            }
        }

        stage("Quality Gate") {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage("OWASP Dependency Check") {
            steps {
                dependencyCheck(
                    additionalArguments: '--scan .',
                    odcInstallation: 'dp-check'
                )
                dependencyCheckPublisher(
                    pattern: '**/dependency-check-report.xml'
                )
            }
        }

        stage("Trivy FS Scan") {
            steps {
                sh "trivy fs --severity HIGH,CRITICAL ."
            }
        }

        stage("Build Docker Image") {
            steps {
                script {
                    def tag = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG : BUILD_NUMBER
                    env.TAG = tag
                    sh "docker build -t temp-image:${env.TAG} ."
                }
            }
        }

        stage("Trivy Image Scan") {
            steps {
                sh "trivy image --severity HIGH,CRITICAL temp-image:${env.TAG}"
            }
        }

        stage("Login, Tag & Push to ECR") {
            steps {
                withCredentials([
                    string(credentialsId: 'accountid', variable: 'AWS_ACCOUNT_ID'),
                    string(credentialsId: 'region', variable: 'AWS_REGION'),
                    [$class: 'AmazonWebServicesCredentialsBinding',
                     credentialsId: 'awscred']
                ]) {
                    script {
                        def ECR_URL = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                        def FINAL_IMAGE = "${ECR_URL}/${IMAGE_REPO}:${env.TAG}"

                        sh """
                            aws ecr get-login-password --region ${AWS_REGION} \
                            | docker login --username AWS --password-stdin ${ECR_URL}
                        """

                        sh "docker tag temp-image:${env.TAG} ${FINAL_IMAGE}"
                        sh "docker push ${FINAL_IMAGE}"
                    }
                }
            }
        }

        stage("Manual Approval") {
            steps {
                input message: "Approve Deployment?"
            }
        }

        stage("Deploy Container") {
            steps {
                script {
                    withCredentials([
                        string(credentialsId: 'accountid', variable: 'AWS_ACCOUNT_ID'),
                        string(credentialsId: 'region', variable: 'AWS_REGION')
                    ]) {

                        def ECR_URL = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                        def FINAL_IMAGE = "${ECR_URL}/${IMAGE_REPO}:${env.TAG}"

                        sh '''
                            EXISTING=$(docker ps -q --filter "publish=80")
                            if [ -n "$EXISTING" ]; then
                                docker stop $EXISTING
                                docker rm $EXISTING
                            fi
                        '''

                        sh "docker run -d --name vprofile -p 80:8080 ${FINAL_IMAGE}"
                    }
                }
            }
        }

        stage("DAST - OWASP ZAP") {
            when {
                beforeAgent true
                expression { params.SKIP_DAST == false }
            }
            steps {
                sh '''
                    echo "Running OWASP ZAP Scan..."

                    docker run --rm \
                      --user root \
                      --network host \
                      -v "$WORKSPACE:/zap/wrk:rw" \
                      zaproxy/zap-stable \
                      zap-baseline.py \
                      -t http://localhost \
                      -r zap_report.html \
                      -J zap_report.json
                '''

                archiveArtifacts artifacts: 'zap_report.html,zap_report.json', allowEmptyArchive: true
            }
        }
    }

    post {
        success {
            echo "✅ Pipeline Completed Successfully"
        }
        failure {
            echo "❌ Pipeline Failed"
        }
        always {
            cleanWs()
        }
    }
}
