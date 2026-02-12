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
        JFROG_URL    = "https://yourcompany.jfrog.io"
        JFROG_DOCKER_REPO = "docker-local"
        JFROG_MAVEN_REPO  = "maven-local"
    }

    stages {

        stage("Clean Workspace") {
            steps { cleanWs() }
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

        stage("Publish Artifact to JFrog") {
            steps {
                withCredentials([string(credentialsId: 'jfrog-api-key', variable: 'JFROG_API_KEY')]) {
                    sh """
                        ${JFROG_CLI}/jfrog config add ${JFROG_SERVER} \
                        --url=${JFROG_URL} \
                        --apikey=${JFROG_API_KEY} \
                        --interactive=false

                        ${JFROG_CLI}/jfrog rt upload "target/*.jar" \
                        ${JFROG_MAVEN_REPO}/ \
                        --server-id=${JFROG_SERVER}
                    """
                }
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
                sh "trivy fs --severity HIGH,CRITICAL --exit-code 1 ."
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

        stage("Push Image to JFrog & Xray Scan") {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'jfrog-docker-login',
                        usernameVariable: 'JF_USER',
                        passwordVariable: 'JF_PASS'
                    )
                ]) {
                    script {

                        def JFROG_IMAGE = "yourcompany.jfrog.io/${JFROG_DOCKER_REPO}/${IMAGE_REPO}:${env.TAG}"

                        sh """
                            docker login yourcompany.jfrog.io \
                            -u ${JF_USER} -p ${JF_PASS}

                            docker tag temp-image:${env.TAG} ${JFROG_IMAGE}
                            docker push ${JFROG_IMAGE}
                        """

                        sh """
                            ${JFROG_CLI}/jfrog rt build-collect-env
                            ${JFROG_CLI}/jfrog rt build-publish vprofile ${BUILD_NUMBER}
                        """

                        sh """
                            ${JFROG_CLI}/jfrog xr scan vprofile/${BUILD_NUMBER} \
                            --server-id=${JFROG_SERVER} \
                            --fail=true
                        """
                    }
                }
            }
        }

        stage("Push to ECR (After Xray Pass)") {
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
