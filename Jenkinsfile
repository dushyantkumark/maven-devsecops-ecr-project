pipeline {

    agent any

    tools {
        maven 'MAVEN3'
        jdk   'JDK17'
    }

    parameters {
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Optional custom image tag override')
        booleanParam(name: 'SKIP_DAST', defaultValue: false, description: 'Skip OWASP ZAP scanning')
    }

    environment {
        SCANNER_HOME   = tool 'sonar-scanner'
        JFROG_CLI      = tool 'jfrog-cli'
        IMAGE_REPO     = "profilemappimg"
        TRIVY_TEMPLATE = "/var/lib/jenkins/.trivy/contrib/html.tpl"
        S3_BUCKET      = "central-report-collection-pocket"
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
                    env.GIT_SHORT     = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                    env.VERSION       = "2.0.${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    env.ACTIVE_BRANCH = env.BRANCH_NAME ?: "devsecops"

                    // If user passed IMAGE_TAG, use it. Otherwise auto-generate based on branch + build.
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
                        ${SCANNER_HOME}/bin/sonar-scanner \
                            -Dsonar.projectKey=vprofile \
                            -Dsonar.projectName=vprofile \
                            -Dsonar.projectVersion=${VERSION} \
                            -Dsonar.branch.name=${ACTIVE_BRANCH} \
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


        stage("Trivy FS Scan [SCA]") {
            steps {
                sh """
                    trivy fs \
                      --scanners vuln \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format template \
                      --template '${TRIVY_TEMPLATE}' \
                      --output trivy-fs-report.html \
                      . || true

                    trivy fs \
                      --scanners vuln \
                      --format json \
                      --output trivy-fs-report.json \
                      . || true

                    trivy fs --format cyclonedx --output trivy-fs-sbom.json . || true
                """

                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'awscred']]) {
                    sh """
                        aws s3 cp trivy-fs-report.json  s3://${S3_BUCKET}/trivy-fs/${VERSION}/
                        aws s3 cp trivy-fs-report.html  s3://${S3_BUCKET}/trivy-fs/${VERSION}/
                    """
                }
            }
        }


        stage("Build Docker Image") {
            steps {
                sh "docker build -t temp-image:${DOCKER_TAG} ."
            }
        }


        stage("Trivy Image Scan [SCA]") {
            steps {
                sh """
                    trivy image \
                      --scanners vuln \
                      --severity LOW,MEDIUM,HIGH,CRITICAL \
                      --format template \
                      --template '${TRIVY_TEMPLATE}' \
                      --output trivy-image-report.html \
                      temp-image:${DOCKER_TAG} || true

                    trivy image \
                      --format json \
                      --output trivy-image-report.json \
                      temp-image:${DOCKER_TAG} || true

                    trivy image \
                      --format cyclonedx \
                      --output trivy-image-sbom.json \
                      temp-image:${DOCKER_TAG} || true
                """

                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'awscred']]) {
                    sh """
                        aws s3 cp trivy-image-report.json  s3://${S3_BUCKET}/trivy-image/${VERSION}/
                        aws s3 cp trivy-image-report.html  s3://${S3_BUCKET}/trivy-image/${VERSION}/
                    """
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

                    # If an older container exists, preserve it for rollback
                    if docker ps -a --format '{{.Names}}' | grep -q "^vprofile$"; then
                        docker stop vprofile
                        docker rename vprofile vprofile_backup
                    fi

                    docker run -d --name vprofile -p 80:8080 temp-image:$DOCKER_TAG
                    sleep 15

                    # Health check
                    if curl -f http://localhost/; then
                        docker rm -f vprofile_backup || true
                    else
                        echo "Deployment failed — rolling back"
                        docker rm -f vprofile
                        docker rename vprofile_backup vprofile
                        docker start vprofile
                        exit 1
                    fi
                '''
            }
        }


        stage("Cleanup Unused Docker Images") {
            steps {
                sh '''
                    echo "Cleaning unused Docker images..."

                    # Remove untagged images
                    docker image prune -f

                    # Remove unused images older than 24 hours
                    docker image prune -a -f --filter "until=24h"

                    echo "Docker cleanup completed."
                '''
            }
        }


        stage("DAST - OWASP ZAP [DAST]") {
            when { expression { params.SKIP_DAST == false } }
            steps {

                script {
                    // Use Jenkins host IP. ZAP inside Docker cannot scan "localhost".
                    env.HOST_IP = sh(
                        script: "hostname -I | awk '{print $1}'",
                        returnStdout: true
                    ).trim()
                }

                sh """
                    echo "Running OWASP ZAP baseline scan against http://${HOST_IP}"

                    docker run --rm \
                        --user root \
                        --network host \
                        -v "$WORKSPACE:/zap/wrk:rw" \
                        zaproxy/zap-stable \
                        zap-baseline.py \
                        -t http://${HOST_IP} \
                        -x zap_report.xml \
                        -J zap_report.json \
                        -r zap_report.html \
                        || true
                """

                // Ensure reports always exist
                sh """
                    [ -f zap_report.json ] || echo '{}' > zap_report.json
                    [ -f zap_report.xml ]  || echo '<zap></zap>' > zap_report.xml
                    [ -f zap_report.html ] || echo '<html>No ZAP Report Generated</html>' > zap_report.html
                """

                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'awscred']]) {
                    sh """
                        aws s3 cp zap_report.json s3://${S3_BUCKET}/zap/${VERSION}/
                        aws s3 cp zap_report.xml  s3://${S3_BUCKET}/zap/${VERSION}/
                        aws s3 cp zap_report.html s3://${S3_BUCKET}/zap/${VERSION}/
                    """
                }
            }
        }
    }


    post {
        always {

            dependencyCheckPublisher pattern: '**/dependency-check-report.xml'

            recordIssues(
                id:   'trivy-fs',
                name: 'Trivy FileSystem Scan',
                tools: [ trivy(pattern: 'trivy-fs-report.json') ]
            )

            recordIssues(
                id:   'trivy-image',
                name: 'Trivy Image Scan',
                tools: [ trivy(pattern: 'trivy-image-report.json') ]
            )

            archiveArtifacts artifacts: '''
                trivy-fs-report.html,
                trivy-image-report.html,
                trivy-fs-report.json,
                trivy-image-report.json,
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
