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
            steps { cleanWs() }
        }

        stage("Checkout Code") {
            steps {
                git branch: 'devsecops',
                    url: 'https://github.com/dushyantkumark/maven-devsecops-ecr-project.git'

                script {
                    env.GIT_COMMIT_ID = sh(
                        script: "git rev-parse --short HEAD",
                        returnStdout: true
                    ).trim()

                    env.BRANCH_NAME = "devsecops"
                }
            }
        }

        stage("Build Application") {
            steps {
                // IMPORTANT: run tests for coverage
                sh 'mvn clean verify'
            }
        }

        stage("Publish Artifact to JFrog") {
            steps {
                script {
                    def VERSION = "2.0.${env.BUILD_NUMBER}"
                    def GROUP_PATH = "com/visualpathit/vprofile/${VERSION}"
                    def ARTIFACT_NAME = "vprofile-${VERSION}.war"

                    sh """
                        ${JFROG_CLI}/jf rt upload \
                        target/vprofile-v2.war \
                        maven-local/${GROUP_PATH}/${ARTIFACT_NAME} \
                        --server-id=${JFROG_SERVER}
                    """
                }
            }
        }

        stage("SonarQube Analysis [SAST]") {
            steps {
                withSonarQubeEnv('sonar-server') {
                    sh """
                        ${SCANNER_HOME}/bin/sonar-scanner \
                        -Dsonar.projectKey=vprofile-devsecops \
                        -Dsonar.projectName=vprofile-devsecops \
                        -Dsonar.projectVersion=${env.BUILD_NUMBER} \
                        -Dsonar.scm.revision=${env.GIT_COMMIT_ID} \
                        -Dsonar.sources=src/main/java \
                        -Dsonar.tests=src/test/java \
                        -Dsonar.java.binaries=target/classes \
                        -Dsonar.java.test.binaries=target/test-classes \
                        -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
                    """
                }
            }
        }

        stage("Quality Gate") {
            steps {
                timeout(time: 3, unit: 'MINUTES') {
                    script {
                        def qg = waitForQualityGate()
                        echo "Quality Gate Status: ${qg.status}"

                        if (qg.status != 'OK') {
                            error "Quality Gate failed: ${qg.status}"
                        }
                    }
                }
            }
        }

        stage("OWASP Dependency Check [SCA]") {
            steps {
                dependencyCheck(
                    additionalArguments: '--scan . --format XML --disableAssembly',
                    odcInstallation: 'dp-check'
                )
            }
        }

        stage("Trivy FS Scan [SCA]") {
            steps {
                sh '''
                    trivy fs \
                      --severity MEDIUM,HIGH,CRITICAL \
                      --format json \
                      --output trivy-fs-report.json \
                      . || true
                '''
            }
        }

        stage("Build Docker Image") {
            steps {
                script {
                    def tag = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG : env.BUILD_NUMBER
                    env.TAG = tag
                    sh "docker build -t temp-image:${env.TAG} ."
                }
            }
        }

        stage("Trivy Image Scan [SCA]") {
            steps {
                sh '''
                    trivy image \
                      --severity MEDIUM,HIGH,CRITICAL \
                      --format json \
                      --output trivy-image-report.json \
                      temp-image:$TAG || true
                '''
            }
        }

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

        stage("Manual Approval") {
            steps {
                input message: "Approve Deployment?"
            }
        }

        stage("Deploy Container (With Rollback)") {
            steps {
                sh '''
                    set -e

                    if docker ps -a --format '{{.Names}}' | grep -q "^vprofile$"; then
                        docker stop vprofile
                        docker rename vprofile vprofile_backup
                    fi

                    docker run -d --name vprofile -p 80:8080 temp-image:$TAG
                    sleep 15

                    if curl -f http://localhost/; then
                        docker rm -f vprofile_backup || true
                    else
                        docker rm -f vprofile
                        docker rename vprofile_backup vprofile
                        docker start vprofile
                        exit 1
                    fi
                '''
            }
        }

        stage("DAST - OWASP ZAP [DAST]") {
            when { expression { params.SKIP_DAST == false } }
            steps {
                sh '''
                    docker run --rm \
                      --network host \
                      -v "$WORKSPACE:/zap/wrk:rw" \
                      zaproxy/zap-stable \
                      zap-baseline.py \
                      -t http://localhost \
                      -x zap_report.xml \
                      -J zap_report.json || true
                '''
            }
        }
    }

    post {
        always {

            dependencyCheckPublisher pattern: '**/dependency-check-report.xml'

            recordIssues(
                id: 'trivy-fs',
                name: 'Trivy FS Scan',
                tools: [trivy(pattern: 'trivy-fs-report.json')]
            )

            recordIssues(
                id: 'trivy-image',
                name: 'Trivy Image Scan',
                tools: [trivy(pattern: 'trivy-image-report.json')]
            )

            archiveArtifacts artifacts: '''
                trivy-fs-report.json,
                trivy-image-report.json,
                dependency-check-report.xml,
                zap_report.xml,
                zap_report.json
            '''.trim(), allowEmptyArchive: true

            cleanWs()
        }
    }
}
