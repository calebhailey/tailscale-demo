# Tailscale Forward Deployed Engineer Demo

* [Overview](#overview)
* [Plan](#roadmap)

## Overview

Build a Tailscale demo that highlights the value proposition of the Tailscale platform, specifically including [Tailscale Subnet Routers]. 
The demo will focus on the benefits of ["gradual deployment"], as well as the ["managed services access"] use case. 

## Roadmap

1.  **Create a demo app**

    * simple go HTTP server 
    * static HTML server w/ embedded "hello world" content that displays host metadata (e.g. hostname or instance ID)
    * minimal HTTP/JSON api endpoints for demo (/api/healthz + /api/readyz)

2.  **Document workstation prerequisites**

    * `tailscale`
    * `aws`
    * `packer`
    * `terraform`
    * `jq`
    * ssh key(s)

3.  **Document tailscale account prerequisites (manual)**

    <!-- TODO -->

4.  **Document AWS account prerequisites (manual)**

    <!-- TODO -->

5.  **[Packer] build AMIs w/ custom app binary**

    * router (dedicated tailscale subnet router with no openssh)
    * app-v1 (no tailscale client)
    * app-v2 (w/ tailscale client)

6.  **[Terraform] infrastructure code**

    * AWS [VPC] (logically isolated virtual network w/ predefined CIDR range)
    * AWS [ALB] (load balancer for the demo app)
    * AWS [ASG] w/ 2x AWS [EC2] instances (tailscale subnet routers w/ tailscale SSH)
    * AWS [ASG] w/ 3x AWS [EC2] instances (demo app + openssh)
    * AWS [ElastiCache] (Valkey) (managed service for demonstrating subnet router value proposition)

7.  **Demo**

    1. `terraform apply` (app v1 w/o tailscale client)
    2. demonstrate subnet router access
       * tailscale ssh to subnet router node(s)
       * openssh access to app instances via private IPs
       * valkey CLI access to Elasticache endpoint
    3. demonstrate gradual deployment
       * edit terraform app AMI ID variable(s)
       * `terraform apply` (app v2 rollout w/ tailscale client)
       * show app instances auto-registering in the tailscale console? 
       * openssh access to app instances via tailnet addresses
    4. `terraform destroy`

8.  **Stretch goals**

    * setup [AWS Outbound Identity Federation] w/ [Tailscale Trust Credentials]?
      TBD if Trust Credentials are available in Tailscale free tier? 🤔 🙏🏽
    * add functional Valkey integration in the demo app? 
    * add [`tsnet`] to the demo app?
    * add AWS EKS w/ tailscale operator? 

<!-- Links -->
[AWS Outbound Identity Federation]: https://aws.amazon.com/identity/federation/outbound-federation/
[Tailscale Subnet Routers]: https://tailscale.com/docs/features/subnet-routers
[Tailscale Trust Credentials]: https://tailscale.com/docs/reference/trust-credentials
[Packer]: https://www.hashicorp.com/en/products/packer
[Terraform]: https://www.hashicorp.com/en/products/terraform
["gradual deployment"]: https://tailscale.com/docs/features/subnet-routers#benefits
["managed services access"]: https://tailscale.com/docs/features/subnet-routers#use-cases
[`tsnet`]: https://tailscale.com/docs/features/tsnet
[VPC]: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
[ALB]: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
[ASG]: https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
[EC2]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html
[ElastiCache]: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.html
