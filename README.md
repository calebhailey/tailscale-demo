# Tailscale Forward Deployed Engineer Demo

* [Overview](#overview)
* [Prerequisites](#prerequisites)
  * [Workstation](#workstation)
* [Local Development](#local-development)
* [Plan](#roadmap)

## Overview

Build a Tailscale demo that highlights the value proposition of the Tailscale platform, specifically including [Tailscale Subnet Routers]. 
The demo will focus on the benefits of ["gradual deployment"], as well as the ["managed services access"] use case. 

## Prerequisites

### Workstation
---------------

This demo and related instructions have been tested exclusively on macOS, but all of the tools should work the same on Linux (and they are available on Windows with some minor adjustments to the documented commands).
References to Linux commands and/or packages are Debian-based Linux distributions. 

1.  **CLI tools**

    This demo requires the following CLI tools: 

    * `curl` (built-in on MacOS, available via the `curl` package on Linux)
    * `openssh` (built-in on MacOS, available via the `openssh-client` package on Linux)
    * `jq` ([`jq` downloads])

    Optional local development tools:

    * `go` for building the demo app
    * `podman` + `podman-compose` for local development ([Podman Installation])
    
      > **NOTE:** podman-compose requires `python3` and `pip3`; install it with:
      >
      > ```
      > pip3 install --user podman-compose
      > ```

    * Docker Desktop (includes Docker engine, CLI, and `docker-compose`) as local development alternative to `podman` ([Docker Desktop Installation])


## Local development

This project contains a sample application that serves a simple static HTML website and HTTP API.

1.  **Run the sample app**

    ```shell
    go run app/main.go  --port 8080 --data app/data.json
    ```

    Visit http://localhost:8080/ in your browser to view the sample app.

    Use `curl` to interact with the sample app API:
    
    ```shell
    $ curl -s http://localhost:8080/api/ping
    pong
    $ curl -i http://localhost:8080/api/healthz
    HTTP/1.1 200 OK
    Content-Type: application/json; charset=utf-8
    X-Request-Id: 418d0416-a571-4681-9768-0d27a8f3cd3a
    Date: Sat, 31 Oct 2026 21:56:48 GMT
    Content-Length: 76

    {"state":"ok","uptime":"00:07:07.821","requests":5,"errors":1,"ready":true}
    $ curl -i http://localhost:8080/api/readyz
    HTTP/1.1 200 OK
    Content-Type: application/json; charset=utf-8
    X-Request-Id: d7362f93-3109-448a-ad46-f0df75fbfabc
    Date: Sat, 31 Oct 2026 21:57:22 GMT
    Content-Length: 15

    {"ready":true}
    ```

    Toggle the app into an unready state via `POST /api/readyz` then `GET /api/readyz` to observe a `503 Service Unavailable` response code: 

    ```shell
    $ curl -i -X POST http://localhost:8080/api/readyz
    HTTP/1.1 200 OK
    Content-Type: application/json; charset=utf-8
    X-Request-Id: c615f7ed-d1cb-4207-bd33-adb8ae8088f0
    Date: Sat, 31 Oct 2026 21:59:00 GMT
    Content-Length: 16

    {"ready":false}
    $ curl -i http://localhost:8080/api/readyz
    HTTP/1.1 503 Service Unavailable
    Content-Type: application/json; charset=utf-8
    X-Request-Id: e551d2b1-7042-404c-b4c3-b054fe61c041
    Date: Sat, 31 Oct 2026 21:59:40 GMT
    Content-Length: 16

    {"ready":false}
    ```

    > **NOTE:** Stop the direct `go run` instance with `Ctrl-C` before starting the Compose stack, since both bind port `8080`.

2.  **Build the sample app**

    ```shell
    mkdir -p dist
    go build -C app -o ../dist/tailscale-demo .
    ```

3.  **Build the sample app container**

    ```shell
    podman build -f containers/app.Containerfile -t tailscale-demo .
    ```

4.  **Run the sample app w/ local load balancer & valkey**

    ```shell
    podman compose up -d
    ```

    _NOTE: for Docker Desktop environments, `docker compose up -d`._

    Preview the load-balanced application at [http://localhost:8080](http://localhost:8080).

5.  **Stop the sample app stack**

    ```shell
    podman compose down -v
    ```

    _NOTE: for Docker Desktop environments, `docker compose down -v`._


## Roadmap
----------

1.  **Create a demo app** ✅

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
[Podman installation]: https://podman.io/docs/installation
[Docker Desktop installation]: https://docs.docker.com/desktop/
[`jq` downloads]: https://jqlang.org/download/
