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
        DT_URL       = "http://localhost:8081"
        TRIVY_TEMPLATE = "/var/lib/jenkins/.trivy/contrib/html.tpl"
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
                    env.GIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                    env.VERSION = "2.0.${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    env.ACTIVE_BRANCH = env.BRANCH_NAME ?: "devsecops"

                    env.DOCKER_TAG = params.IMAGE_TAG?.trim() ?
                                     params.IMAGE_TAG :
                                     "${env.ACTIVE_BRANCH}-${env.BUILD_NUMBER}"
                }
            }
        }

        stage("Build Application") {
            steps {
                sh 'mvn clean install -DskipTests'
            }
        }

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
                    waitForQualityGate abortPipeline: false
                }
            }
        }

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

        // =====================================================
        // Trivy FS Scan (Colorful HTML + JSON + SBOM)
        // =====================================================
        stage("Trivy FS Scan [SCA]") {
            steps {
                sh """
                    trivy fs --scanners vuln \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format template \
                      --template '@/var/lib/jenkins/.trivy/contrib/html.tpl' \
                      --output trivy-fs-report.html \
                      . || true

                    trivy fs --scanners vuln \
                      --format json \
                      --output trivy-fs-report.json \
                      . || true

                    trivy fs \
                      --format cyclonedx \
                      --output trivy-fs-sbom.json \
                      . || true
                """
            }
        }

        stage("Build Docker Image") {
            steps {
                sh "docker build -t temp-image:${env.DOCKER_TAG} ."
            }
        }

        // =====================================================
        // Trivy Image Scan (Colorful HTML + JSON + SBOM)
        // =====================================================
        stage("Trivy Image Scan [SCA]") {
            steps {
                sh """
                    trivy image --scanners vuln \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format template \
                      --template '@/var/lib/jenkins/.trivy/contrib/html.tpl' \
                      --output trivy-image-report.html \
                      temp-image:${env.DOCKER_TAG} || true

                    trivy image --scanners vuln \
                      --format json \
                      --output trivy-image-report.json \
                      temp-image:${env.DOCKER_TAG} || true

                    trivy image \
                      --format cyclonedx \
                      --output trivy-image-sbom.json \
                      temp-image:${env.DOCKER_TAG} || true
                """
            }
        }

        stage("Upload SBOM to Dependency-Track") {
            steps {
                withCredentials([string(credentialsId: 'dtrack-api-key', variable: 'DT_API_KEY')]) {
                    sh '''
                        curl -X POST $DT_URL/api/v1/bom \
                          -H "X-Api-Key: $DT_API_KEY" \
                          -F "projectName=vprofile-fs" \
                          -F "projectVersion=${VERSION}" \
                          -F "autoCreate=true" \
                          -F "bom=@trivy-fs-sbom.json"

                        curl -X POST $DT_URL/api/v1/bom \
                          -H "X-Api-Key: $DT_API_KEY" \
                          -F "projectName=vprofile-image" \
                          -F "projectVersion=${VERSION}" \
                          -F "autoCreate=true" \
                          -F "bom=@trivy-image-sbom.json"
                    '''
                }
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
                trivy-fs-report.html,
                trivy-image-report.html,
                trivy-fs-report.json,
                trivy-image-report.json,
                trivy-fs-sbom.json,
                trivy-image-sbom.json,
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
