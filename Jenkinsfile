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
        JFROG_CLI    = tool 'jfrog-cli'
        IMAGE_REPO   = "profilemappimg"
        JFROG_SERVER = "jfrog-instance"
        JFROG_DOCKER_REPO = "docker-local"
        JFROG_MAVEN_REPO  = "maven-local"
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

        // ---------------- JFROG ARTIFACT UPLOAD ----------------

        stage("Publish Artifact to JFrog") {
            steps {
                sh '''
                    $JFROG_CLI/jf rt upload "target/*.war" \
                    maven-local/ \
                    --server-id=jfrog-instance
                '''
            }
        }

        // ---------------- SONAR ----------------

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

        // ---------------- OWASP ----------------

        stage("OWASP Dependency Check") {
            steps {
                dependencyCheck(
                    additionalArguments: '--scan .',
                    odcInstallation: 'dp-check'
                )
                dependencyCheckPublisher(pattern: '**/dependency-check-report.xml')
            }
        }

        // ---------------- TRIVY ----------------

        stage("Trivy FS Scan") {
            steps {
                sh 'trivy fs --severity HIGH,CRITICAL --exit-code 1 .'
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
                sh "trivy image --severity HIGH,CRITICAL --exit-code 1 temp-image:${env.TAG}"
            }
        }

        // ---------------- PUSH DOCKER TO JFROG ----------------

        stage("Push Image to JFrog") {
            steps {
                script {
                    def JFROG_HOST = "3.110.216.190:8082"
                    def JFROG_IMAGE = "${JFROG_HOST}/${JFROG_DOCKER_REPO}/${IMAGE_REPO}:${env.TAG}"

                    sh """
                        docker login ${JFROG_HOST} -u admin -p <YOUR_API_KEY>
                        docker tag temp-image:${env.TAG} ${JFROG_IMAGE}
                        docker push ${JFROG_IMAGE}
                    """
                }
            }
        }

        // ---------------- PUSH TO ECR ----------------

        stage("Push to ECR") {
            steps {
                withCredentials([
                    string(credentialsId: 'accountid', variable: 'AWS_ACCOUNT_ID'),
                    string(credentialsId: 'region', variable: 'AWS_REGION'),
                    [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'awscred']
                ]) {
                    script {

                        def ECR_URL = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                        def FINAL_IMAGE = "${ECR_URL}/${IMAGE_REPO}:${env.TAG}"

                        sh """
                            aws ecr get-login-password --region ${AWS_REGION} \
                            | docker login --username AWS --password-stdin ${ECR_URL}

                            docker tag temp-image:${env.TAG} ${FINAL_IMAGE}
                            docker push ${FINAL_IMAGE}
                        """
                    }
                }
            }
        }

        // ---------------- MANUAL APPROVAL ----------------

        stage("Manual Approval") {
            steps {
                input message: "Approve Deployment?"
            }
        }

        // ---------------- DEPLOY ----------------

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

        // ---------------- DAST ----------------

        stage("DAST - OWASP ZAP") {
            when {
                expression { params.SKIP_DAST == false }
            }
            steps {
                script {
                    def exitCode = sh(
                        script: '''
                            docker run --rm \
                              --user root \
                              --network host \
                              -v "$WORKSPACE:/zap/wrk:rw" \
                              zaproxy/zap-stable \
                              zap-baseline.py \
                              -t http://localhost \
                              -r zap_report.html \
                              -J zap_report.json
                        ''',
                        returnStatus: true
                    )

                    if (exitCode == 1) {
                        error("High severity vulnerabilities found! Failing build.")
                    }
                }

                archiveArtifacts artifacts: 'zap_report.html,zap_report.json', allowEmptyArchive: true
            }
        }
    }

    post {
        success { echo "✅ Pipeline Completed Successfully" }
        failure { echo "❌ Pipeline Failed" }
        always { cleanWs() }
    }
}
