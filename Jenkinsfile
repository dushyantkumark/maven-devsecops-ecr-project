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

        // Using Global Variables from Jenkins
        AWS_ACCOUNT_ID = "${accountid}"
        AWS_REGION     = "${region}"

        //IMAGE_REPO     = "vprofileappimg"
        IMAGE_REPO     = "profilemappimg"
        IMAGE_TAG      = "${BUILD_NUMBER}"

        ECR_URL        = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        IMAGE_NAME     = "${ECR_URL}/${IMAGE_REPO}"

        registryCredential = 'awscreds'
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

        stage("Build") {
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
                dependencyCheck additionalArguments: '--scan .',
                odcInstallation: 'dp-check'
                dependencyCheckPublisher pattern: '**/dependency-check-report.xml'
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
                    def tag = params.IMAGE_TAG ? params.IMAGE_TAG : BUILD_NUMBER
                    env.FINAL_IMAGE = "${IMAGE_NAME}:${tag}"

                    sh "docker build -t ${env.FINAL_IMAGE} ."
                }
            }
        }

        stage("Trivy Image Scan") {
            steps {
                sh "trivy image --severity HIGH,CRITICAL ${env.FINAL_IMAGE}"
            }
        }

        stage("Login to AWS ECR") {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'awscreds']]) {
                    sh """
                    aws ecr get-login-password --region ${AWS_REGION} \
                    | docker login --username AWS --password-stdin ${ECR_URL}
                    """
                }
            }
        }

        stage("Push Image to ECR") {
            steps {
                sh "docker push ${env.FINAL_IMAGE}"
            }
        }

        stage("Manual Approval") {
            steps {
                input message: "Approve deployment?"
            }
        }

        stage("Deploy Container") {
            steps {
                sh "docker rm -f vprofile || true"
                sh "docker run -d --name vprofile -p 80:8080 ${env.FINAL_IMAGE}"
            }
        }

        stage("DAST - OWASP ZAP") {
            when {
                expression { return !params.SKIP_DAST }
            }
            steps {
                sh """
                docker run --rm --network host \
                -v \$(pwd):/zap/wrk:rw \
                zaproxy/zap-stable zap-baseline.py \
                -t http://localhost \
                -r zap_report.html -J zap_report.json
                """
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
