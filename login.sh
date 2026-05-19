export AWS_PROFILE=concntric-production
aws --profile concntric-production sso login
export CODEARTIFACT_AUTH_TOKEN=`aws codeartifact --profile concntric-production get-authorization-token --domain concntric --domain-owner 705137920128 --region us-west-2 --query authorizationToken --output text`
task login-to-aws-ecs