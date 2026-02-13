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
        JFROG_SERVER = "jfrog-artifactory"
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

        // ================= JFROG VERSIONED UPLOAD =================

        stage("Publish Artifact to JFrog") {
            steps {
                script {

                    def VERSION = "2.0.${env.BUILD_NUMBER}"
                    def GROUP_PATH = "com/visualpathit/vprofile/${VERSION}"
                    def ARTIFACT_NAME = "vprofile-${VERSION}.war"

                    echo "Uploading artifact version: ${VERSION}"

                    sh """
                        ${JFROG_CLI}/jf rt upload \
                        target/vprofile-v2.war \
                        maven-local/${GROUP_PATH}/${ARTIFACT_NAME} \
                        --server-id=${JFROG_SERVER}
                    """
                }
            }
        }

        // ================= SONAR =================

        stage("SonarQube Analysis [SAST : Static Application Security Testing]") {
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

        // ================= OWASP =================

        stage("OWASP Dependency Check [SCA : Software Composition Analysis]") {
            steps {
                dependencyCheck(
                    additionalArguments: '''
                        --scan .
                        --format HTML
                        --format XML
                        --disableAssembly
                    ''',
                    odcInstallation: 'dp-check'
                )

                dependencyCheckPublisher(
                    pattern: '**/dependency-check-report.xml'
                )
            }
        }

        // ================= TRIVY FS =================

        stage("Trivy FS Scan [SCA : Software Composition Analysis]") {
            steps {
                sh '''
                    trivy fs \
                      --severity MEDIUM,HIGH,CRITICAL \
                      --format html \
                      -o trivy-fs-report.html \
                      . || true
                '''
            }
        }

        // ================= DOCKER BUILD =================

        stage("Build Docker Image") {
            steps {
                script {
                    def tag = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG : env.BUILD_NUMBER
                    env.TAG = tag
                    sh "docker build -t temp-image:${env.TAG} ."
                }
            }
        }

        stage("Trivy Image Scan [SCA : Software Composition Analysis]") {
            steps {
                sh """
                    trivy image \
                      --severity MEDIUM,HIGH,CRITICAL \
                      --format html \
                      -o trivy-image-report.html \
                      temp-image:${env.TAG} || true
                """
            }
        }

        // ================= PUSH TO ECR =================

        stage("Push to ECR") {
            steps {
                withCredentials([
                    string(credentialsId: 'accountid', variable: 'AWS_ACCOUNT_ID'),
                    string(credentialsId: 'region', variable: 'AWS_REGION'),
                    [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'awscred']
                ]) {
                    sh '''
                        ECR_URL=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

                        aws ecr get-login-password --region $AWS_REGION \
                        | docker login --username AWS --password-stdin $ECR_URL

                        docker tag temp-image:$TAG $ECR_URL/profilemappimg:$TAG
                        docker push $ECR_URL/profilemappimg:$TAG
                    '''
                }
            }
        }

        // ================= MANUAL APPROVAL =================

        stage("Manual Approval") {
            steps {
                input message: "Approve Deployment?"
            }
        }

        // ================= DEPLOY =================

        stage("Deploy Container") {
            steps {
                withCredentials([
                    string(credentialsId: 'accountid', variable: 'AWS_ACCOUNT_ID'),
                    string(credentialsId: 'region', variable: 'AWS_REGION')
                ]) {
                    sh '''
                        ECR_URL=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
                        IMAGE=$ECR_URL/profilemappimg:$TAG

                        EXISTING=$(docker ps -q --filter "publish=80")
                        if [ -n "$EXISTING" ]; then
                            docker stop $EXISTING
                            docker rm $EXISTING
                        fi

                        docker run -d --name vprofile -p 80:8080 $IMAGE
                    '''
                }
            }
        }

        // ================= DAST =================

        stage("DAST - OWASP ZAP [DAST : Dynamic Application Security Testing]") {
            when {
                expression { params.SKIP_DAST == false }
            }
            steps {
                sh '''
                    docker run --rm \
                      --user root \
                      --network host \
                      -v "$WORKSPACE:/zap/wrk:rw" \
                      zaproxy/zap-stable \
                      zap-baseline.py \
                      -t http://localhost \
                      -r zap_report.html \
                      -J zap_report.json || true
                '''

                archiveArtifacts artifacts: 'zap_report.html,zap_report.json', allowEmptyArchive: true
            }
        }

        // ================= ARCHIVE REPORTS =================

        stage("Archive Security Reports") {
            steps {
                archiveArtifacts artifacts: '''
                    trivy-fs-report.html,
                    trivy-image-report.html,
                    dependency-check-report.html,
                    zap_report.html,
                    zap_report.json
                '''.trim(),
                allowEmptyArchive: true
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
