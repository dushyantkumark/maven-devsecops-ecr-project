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
            steps { checkout scm }
        }

        stage("Set Build Variables") {
            steps {
                script {
                    env.VERSION = "2.0.${env.BUILD_NUMBER}"
                    env.ACTIVE_BRANCH = env.BRANCH_NAME ?: "devsecops"

                    env.DOCKER_TAG = params.IMAGE_TAG?.trim() ?
                                     params.IMAGE_TAG :
                                     "${env.ACTIVE_BRANCH}-${env.BUILD_NUMBER}"

                    echo "Branch: ${env.ACTIVE_BRANCH}"
                    echo "Version: ${env.VERSION}"
                    echo "Docker Tag: ${env.DOCKER_TAG}"
                }
            }
        }

        stage("Build Application") {
            steps {
                sh 'mvn clean install -DskipTests'
            }
        }

        stage("Publish Artifact to JFrog") {
            steps {
                script {
                    def GROUP_PATH = "com/visualpathit/vprofile/${env.VERSION}"
                    def ARTIFACT_NAME = "vprofile-${env.VERSION}.war"

                    sh """
                        ${env.JFROG_CLI}/jf rt upload \
                        target/vprofile-v2.war \
                        maven-local/${GROUP_PATH}/${ARTIFACT_NAME} \
                        --server-id=${env.JFROG_SERVER}
                    """
                }
            }
        }

        // =========================
        // SAST - SonarQube
        // =========================
        stage("SonarQube Analysis [SAST]") {
            steps {
                withSonarQubeEnv('sonar-server') {
                    sh """
                        ${env.SCANNER_HOME}/bin/sonar-scanner \
                        -Dsonar.projectKey=vprofile \
                        -Dsonar.projectName=vprofile \
                        -Dsonar.projectVersion=${env.VERSION} \
                        -Dsonar.branch.name=${env.ACTIVE_BRANCH} \
                        -Dsonar.sources=src \
                        -Dsonar.java.binaries=target/classes
                    """
                }
            }
        }

        stage("Quality Gate") {
            steps {
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        // =========================
        // SCA - OWASP Dependency Check
        // =========================
        stage("OWASP Dependency Check [SCA]") {
            steps {
                dependencyCheck(
                    additionalArguments: '''
                        --scan .
                        --format XML
                        --format HTML
                        --disableAssembly
                    ''',
                    odcInstallation: 'dp-check'
                )
            }
        }

        // =========================
        // SCA - Trivy FS
        // =========================
        stage("Trivy FS Scan [SCA]") {
            steps {
                sh '''
                    # JSON report
                    trivy fs \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format json \
                      --output trivy-fs-report.json \
                      . || true

                    # HTML report
                    trivy fs \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format template \
                      --template "@/usr/local/share/trivy/templates/html.tpl" \
                      --output trivy-fs-report.html \
                      . || true
                '''
            }
        }

        stage("Build Docker Image") {
            steps {
                sh "docker build -t temp-image:${env.DOCKER_TAG} ."
            }
        }

        // =========================
        // SCA - Trivy Image
        // =========================
        stage("Trivy Image Scan [SCA]") {
            steps {
                sh '''
                    # JSON report
                    trivy image \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format json \
                      --output trivy-image-report.json \
                      temp-image:$DOCKER_TAG || true

                    # HTML report
                    trivy image \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format template \
                      --template "@/usr/local/share/trivy/templates/html.tpl" \
                      --output trivy-image-report.html \
                      temp-image:$DOCKER_TAG || true
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

                        docker tag temp-image:$DOCKER_TAG \
                                   $ECR_URL/profilemappimg:$DOCKER_TAG

                        docker push $ECR_URL/profilemappimg:$DOCKER_TAG
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

                    docker run -d --name vprofile -p 80:8080 temp-image:$DOCKER_TAG
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

        // =========================
        // DAST - OWASP ZAP
        // =========================
        stage("DAST - OWASP ZAP [DAST]") {
            when { expression { params.SKIP_DAST == false } }
            steps {
                sh '''
                    docker run --rm \
                      --user root \
                      --network host \
                      -v "$WORKSPACE:/zap/wrk:rw" \
                      zaproxy/zap-stable \
                      zap-baseline.py \
                      -t http://localhost \
                      -x zap_report.xml \
                      -J zap_report.json \
                      -r zap_report.html || true
                '''
            }
        }
    }

    post {
        always {

            dependencyCheckPublisher pattern: '**/dependency-check-report.xml'

            recordIssues(
                id: 'trivy-fs',
                name: 'Trivy FileSystem Scan',
                tools: [trivy(pattern: 'trivy-fs-report.json')]
            )

            recordIssues(
                id: 'trivy-image',
                name: 'Trivy Image Scan',
                tools: [trivy(pattern: 'trivy-image-report.json')]
            )

            archiveArtifacts artifacts: '''
                trivy-fs-report.json,
                trivy-fs-report.html,
                trivy-image-report.json,
                trivy-image-report.html,
                dependency-check-report.xml,
                dependency-check-report.html,
                zap_report.xml,
                zap_report.json,
                zap_report.html
            '''.trim(), allowEmptyArchive: true

            cleanWs()
        }
    }
}
