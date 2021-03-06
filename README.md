## Description
Example repo showing how you can deploy a celery application with an 
api, worker and scheduler to ECS using Fargate and Django as the web framework.

The infrastructure layout can be used with any of the following 
languages as they all have their own implementation of celery.

The commands for the task definitions will be different.

- python
- rust
- golang
- nodejs

## Cost
With a minimal amount of traffic, this infrastructure configuration in AWS costs ~$5-$6/day to run.


## Resources
- [Installing Docker](https://docs.docker.com/engine/install/linux-postinstall/)
- [Post Install Docker Steps (for Linux users)](https://docs.docker.com/engine/install/linux-postinstall/)
- [Installing Docker Compose](https://docs.docker.com/compose/install/#install-compose)
- [Open docker TCP port on Ubuntu (necessary to run a remote python interpreter using docker)](https://medium.com/@ssmak/how-to-enable-docker-remote-api-on-docker-host-7b73bd3278c6)