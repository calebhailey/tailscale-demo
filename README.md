# Tailscale Forward Deployed Engineer Demo

* [Overview](#overview)
* [Prerequisites](#prerequisites)
  * [Workstation](#workstation)
  * [Tailscale Account](#tailscale-account)
  * [AWS Account](#aws-account)
  * [Identity Federation](#identity-federation)
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

1.  **Tailscale**

    This demo requires a free Tailscale account and a workstation with Tailscale installed.
    Please visit the [Tailscale quickstart] to learn more.

    To verify `tailscale` CLI installation, open Tailscale Settings and find "CLI Integration":

    ![](docs/img/cli-setup-1.png)

    Tap "Show me how" to view the CLI Integration view:

    ![](docs/img/cli-setup-2.png)

    Tap "Add now" to install the `tailscale` CLI on your `$PATH`:

    ![](docs/img/cli-setup-3.png)

    Verify the `tailscale` CLI is installed by running the `tailscale status` command:

    ```shell
    $ tailscale status
    100.101.102.103  hello.ts.net                       hello@        linux  -
    100.xx.xx.xx     workstation                        username@     macOS  -
    ```

1.  **CLI tools**

    This demo requires the following CLI tools: 

    * `curl` (built-in on MacOS, available via the `curl` package on Linux)
    * `openssh` (built-in on MacOS, available via the `openssh-client` package on Linux)
    * `jq` ([`jq` downloads])
    * `aws` CLI (see [AWS Account](#aws-account) prerequisites, below)

    Optional local development tools:

    * `go` for building the demo app
    * `podman` + `podman-compose` for local development ([Podman Installation])
    
      > **NOTE:** podman-compose requires `python3` and `pip3`; install it with:
      >
      > ```
      > pip3 install --user podman-compose
      > ```

    * Docker Desktop (includes Docker engine, CLI, and `docker-compose`) as local development alternative to `podman` ([Docker Desktop Installation])

1.  **Generate an SSH key**

    We will use SSH keys to demonstrate conventional OpenSSH connectivity. 

    ```bash
    ssh-keygen -t ed25519 -f ~/.ssh/tailscale-demo -C "tailscale-demo"
    ```

### Tailscale Account
---------------------

Sign in to your Tailscale account, and configure the tailnet policies we'll use for the demo. Define tags for the router and application nodes, allow Tailscale SSH to the router tag, and auto-approve the VPC subnet route advertised by router-tagged instances.

1.  **Create Tailscale Tags**

    Add Tailscale Tags for `tailscale-demo-router` and `tailscale-demo-app` nodes.

    Use the Tailscale Console → Access Controls → Definitions → [Tags](https://console.tailscale.com/admin/acls/visual/tags) view, or edit your tailnet `"tagOwners"` policy to include:

    ```json
    "tagOwners": {
      "tag:tailscale-demo-router": ["you@example.com"],
      "tag:tailscale-demo-app": ["you@example.com"]
    }
    ```

2.  **Add Tailscale SSH policy**

    Allow Tailscale SSH for `tag:tailscale-demo-router` destinations.

    Use the Tailscale Console → Access Controls → Policies → [Tailscale SSH](https://console.tailscale.com/admin/acls/visual/tailscale-ssh) view, or edit your tailnet `"ssh"` policy to include:

    ```json
    "ssh": [
      {
        "src": ["you@example.com"],
        "dst": ["tag:tailscale-demo-router"],
        "users": ["autogroup:nonroot"],
        "action": "accept"
      }
    ],
    ```

    _NOTE: if the user’s Tailnet has restrictive general grants/ACLs, they must also permit network access to the router tag and 10.0.42.0/24. The SSH rule alone governs SSH authorization, not necessarily broader network reachability._

3.  **Add Auto Approvers policy**

    Auto approve the `10.0.42.0/24` VPC subnet route that will be advertised by demo router instances tagged `tag:tailscale-demo-router`.

    Use the Tailscale Console → Access Controls → Policies → [Auto Approvers](https://console.tailscale.com/admin/acls/visual/auto-approvers) view, or edit your tailnet `"autoApprovers"` policy to include:

    ```json
    "autoApprovers": {
       "routes": {
         "10.0.42.0/24": ["tag:tailscale-demo-router"]
       }
     }
    ```

### AWS Account
---------------

This demo requires an [Amazon Web Services] account with advanced features enabled. 
Use an existing account or follow these steps to create a new one.

1.  **Create an AWS account**

    Follow the instructions as [Sign up for AWS (advanced)] to create a new AWS account.

2.  **Secure administrative access**

    Enable root-user MFA, then follow [Create an IAM user] to create an administrative IAM user and attach the AWS managed [AdministratorAccess] policy.

3.  **Install and configure the AWS CLI**

    Follow [Getting started with the AWS CLI] to install the CLI and configure it with non-root credentials.

4.  **Verify access to the VPC API**

    ```shell
    aws ec2 describe-vpcs \
            --region us-east-2 \
            --filters Name=isDefault,Values=true \
            --query 'Vpcs[0].VpcId' \
            --output text
    ```

### Identity Federation
-----------------------

Next let's configure passwordless AWS-to-Tailnet workload identity.

1.  **Enable [AWS Outbound Identity Federation]**

    ```shell
    $ aws iam enable-outbound-web-identity-federation
    {
        "IssuerIdentifier": "https://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.tokens.sts.global.api.aws"
    }
    ```

    _NOTE: if you get an "already enabled" error, run `aws iam get-outbound-web-identity-federation-info` to get the already-configured OIDC issuer URL.

2.  **Create two Tailscale OIDC Trust Credentials**

    Add one Tailscale Trust Credential per IAM Role:

    ```
    arn:aws:iam::<ACCOUNT_ID>:role/tailscale-demo-router
    arn:aws:iam::<ACCOUNT_ID>:role/tailscale-demo-app
    ```

    Use the Tailscale Console → Settings → [Trust Credentials](https://console.tailscale.com/admin/settings/trust-credentials) view and add credentials with the following settings:

    * Select "OpenID Connect" to setup a trust relationship with AWS

    * Give the trust relationship a name (e.g. `aws-tailscale-demo-router` or `aws-tailscale-demo-app`)

    * Provide your AWS Outbound Identity Federation issuer URL from step 1, above

      ```
      https://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.tokens.sts.global.api.aws
      ```
    
    * Provide an AWS IAM Role ARN as the trust credential subject; e.g.:

      ```
      arn:aws:iam::<ACCOUNT_ID>:role/tailscale-demo-router
      ```

      > Use the `aws` CLI to obtain your AWS account ID
      >
      > ```shell
      > $ aws sts get-caller-identity --query Account --output text
      > ```

    * Select "Continue"

    * Select the "Keys" section, enable the "Auth Keys" **write permission**, and select the corresponding tag you created, above

      ```
      tag:tailscale-demo-router
      ```

    * Select "Generate Credential"

    * Record the provided client ID and audience configuration values.

    Repeat these steps to create a trust relationship for the app instances.

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

2.  **Document workstation prerequisites** ✅

    * `tailscale`
    * `aws`
    * `packer`
    * `terraform`
    * `jq`
    * ssh key(s)

3.  **Document tailscale account prerequisites (manual)** ✅

4.  **Document AWS account prerequisites (manual)** ✅

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

    * setup [AWS Outbound Identity Federation] w/ [Tailscale Trust Credentials] ✅
    * add functional Valkey integration in the demo app? 
    * add [`tsnet`] to the demo app?
    * add AWS EKS w/ tailscale operator? 

<!-- Links -->
["gradual deployment"]: https://tailscale.com/docs/features/subnet-routers#benefits
["managed services access"]: https://tailscale.com/docs/features/subnet-routers#use-cases
[`jq` downloads]: https://jqlang.org/download/
[`tsnet`]: https://tailscale.com/docs/features/tsnet
[ALB]: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
[Amazon Web Services]: https://aws.amazon.com
[ASG]: https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
[AWS Outbound Identity Federation]: https://aws.amazon.com/identity/federation/outbound-federation/
[AdministratorAccess]: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AdministratorAccess.html
[Create an IAM user]: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html
[Docker Desktop installation]: https://docs.docker.com/desktop/
[EC2]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html
[ElastiCache]: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.html
[Getting started with the AWS CLI]: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html
[Packer]: https://www.hashicorp.com/en/products/packer
[Podman installation]: https://podman.io/docs/installation
[Sign up for AWS (advanced)]: https://docs.aws.amazon.com/accounts/latest/reference/getting-started.html
[tailnet]: https://tailscale.com/docs/concepts/tailnet
[Tailscale Console]: https://console.tailscale.com/admin/
[Tailscale quickstart]: https://tailscale.com/docs/how-to/quickstart
[Tailscale Subnet Routers]: https://tailscale.com/docs/features/subnet-routers
[Tailscale tag definitions]: https://tailscale.com/docs/features/tags
[Tailscale Trust Credentials]: https://tailscale.com/docs/reference/trust-credentials
[Terraform]: https://www.hashicorp.com/en/products/terraform
[VPC]: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
