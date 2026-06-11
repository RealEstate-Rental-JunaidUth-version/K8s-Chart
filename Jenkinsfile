pipeline {
    agent any
    
    parameters {
        choice(name: 'APP_NAME', 
               choices: ['gateway-service', 'property-microservice', 'user-management-service','property-recommendation-engine', 'tenant-risk-scoring', 'rental-agreement-microservice', 'ml-pricesuggestionmodel', 'predictive-heatmaps-of-neighborhood-price-evolution','public-app','notification-service', 'config-service', 'auth-server'], 
               description: 'Select the microservice to promote to Production')
    }

    environment {
        GITOPS_REPO = "github.com/RealEstate-Rental-JunaidUth-version/K8s-Chart.git"
        CREDENTIALS_ID = 'reel-estate-github-app'
    }

    stages {
        stage('Promote Tag: Staging -> Production') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: "${env.CREDENTIALS_ID}", 
                                                      passwordVariable: 'GIT_PASS', 
                                                      usernameVariable: 'GIT_USER')]) {
                        
                        // 1. Clone the Chart Repo
                        sh 'git clone https://x-access-token:$GIT_PASS@' + env.GITOPS_REPO + ' gitops-temp'
                        
                        dir('gitops-temp') {
                            // 2. Read the current tag from staging for the selected app
                            def stagingTag = sh(
                                script: "yq '.microservices.\"${params.APP_NAME}\".tag' ./values-staging.yaml", 
                                returnStdout: true
                            ).trim()

                            if (stagingTag == "latest" || stagingTag == "" || stagingTag == "null") {
                                error "❌ Could not find a valid tag for ${params.APP_NAME} in values-staging.yaml"
                            }

                            echo "🚀 Promoting ${params.APP_NAME} version ${stagingTag} to Production..."

                            // 3. Update the Production values file
                            sh "yq -i '.microservices.\"${params.APP_NAME}\".tag = \"${stagingTag}\"' ./values-prod.yaml"

                            // 4. Commit and Push
                            sh """
                                git config user.email "jenkins@yourdomain.com"
                                git config user.name "Jenkins Promotion Bot"
                                git add values-prod.yaml
                                git commit -m "chore(prod): promote ${params.APP_NAME} to ${stagingTag} [skip ci]"
                                git push https://x-access-token:\$GIT_PASS@${env.GITOPS_REPO} HEAD:main
                            """
                        }
                    }
                }
            }
        }
    }
    
    post {
        always {
            sh "rm -rf gitops-temp"
        }
        success {
            echo "✅ Successfully promoted ${params.APP_NAME} to Production. ArgoCD will now sync the 'prod' namespace."
        }
    }
}