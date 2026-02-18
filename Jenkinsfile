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
        DT_URL       = "http://localhost:8081"
    }

    stages {

        stage("Checkout") {
            steps { checkout scm }
        }

        stage("Set Build Variables") {
            steps {
                script {
                    env.GIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                    env.VERSION = "2.0.${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    env.ACTIVE_BRANCH = env.BRANCH_NAME ?: "devsecops"

                    echo "Version: ${env.VERSION}"
                }
            }
        }

        stage("Build Application") {
            steps {
                sh 'mvn clean install -DskipTests'
            }
        }

        stage("Trivy FS Scan") {
            steps {
                sh '''
                    trivy fs --format cyclonedx \
                        --output trivy-fs-sbom.json .
                '''
            }
        }

        stage("Build Docker Image") {
            steps {
                sh "docker build -t vprofile:${VERSION} ."
            }
        }

        stage("Trivy Image Scan") {
            steps {
                sh '''
                    trivy image --format cyclonedx \
                        --output trivy-image-sbom.json \
                        vprofile:${VERSION}
                '''
            }
        }

        stage("Upload SBOM to Dependency-Track") {
            steps {
                withCredentials([string(credentialsId: 'dtrack-api-key', variable: 'DT_API_KEY')]) {
                    sh '''
                        echo "Uploading Filesystem SBOM..."

                        curl -s -X POST $DT_URL/api/v1/bom \
                          -H "X-Api-Key: $DT_API_KEY" \
                          -F "projectName=vprofile-fs" \
                          -F "projectVersion=${VERSION}" \
                          -F "classifier=${ACTIVE_BRANCH}" \
                          -F "isLatest=true" \
                          -F "autoCreate=true" \
                          -F "bom=@trivy-fs-sbom.json"

                        echo "Uploading Container Image SBOM..."

                        curl -s -X POST $DT_URL/api/v1/bom \
                          -H "X-Api-Key: $DT_API_KEY" \
                          -F "projectName=vprofile-image" \
                          -F "projectVersion=${VERSION}" \
                          -F "classifier=${ACTIVE_BRANCH}" \
                          -F "isLatest=true" \
                          -F "autoCreate=true" \
                          -F "bom=@trivy-image-sbom.json"
                    '''
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: '''
                trivy-fs-sbom.json,
                trivy-image-sbom.json
            '''.trim(), allowEmptyArchive: true

            cleanWs()
        }
    }
}