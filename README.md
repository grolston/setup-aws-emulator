# Setup AWS Emulator

[![Test](https://github.com/grolston/setup-aws-emulator/actions/workflows/test.yml/badge.svg)](https://github.com/grolston/setup-aws-emulator/actions/workflows/test.yml)

A GitHub Action that installs and starts [AWS Emulator](https://github.com/aws/aws-emulator), a local emulator of the AWS APIs published by AWS, and points the AWS CLI and AWS SDKs at it.

Use it to test infrastructure scripts, AWS CLI automation, and application code in CI **without an AWS account, AWS credentials, or any cost**. Requests go to an emulator running on the runner, not to AWS, so tests are fast, isolated, and safe to run on every pull request.

```yaml
- uses: grolston/setup-aws-emulator@v1

- run: aws s3 mb s3://my-bucket   # Runs against the emulator, not AWS
```

## Why

Shifting AWS testing left usually runs into the same problems: tests need credentials, a sandbox account, cleanup, and they cost money. AWS Emulator removes those problems by serving the AWS APIs locally. This action does the setup for you in one step:

- Downloads the AWS Emulator package and **verifies its GPG signature** against the AWS publishing key.
- Installs it and starts it in the background on `https://127.0.0.1:9297`.
- Waits until the emulator reports healthy, and fails the step with the emulator log if it does not.
- Exports `AWS_ENDPOINT_URL`, the generated credentials, Region, and CA certificate, so the AWS CLI and SDKs in later steps use the emulator with **no changes to your code or commands**.
- Overrides any AWS credentials set earlier in the job, so tests can't reach a real AWS account by accident.

## Usage

### Test AWS CLI commands

```yaml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Setup AWS Emulator
        uses: grolston/setup-aws-emulator@v1

      - name: Check the emulator identity
        run: aws sts get-caller-identity   # Account: 000000000000

      - name: Run scripts that call the AWS CLI
        run: |
          aws s3 mb s3://artifacts
          aws s3 cp ./build/app.zip s3://artifacts/app.zip
          aws dynamodb create-table \
            --table-name orders \
            --attribute-definitions AttributeName=id,AttributeType=S \
            --key-schema AttributeName=id,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST
          ./scripts/deploy-config.sh   # Your own script, unchanged
```

### Test application code with an AWS SDK

The exported environment works with the AWS SDKs that read standard AWS environment variables.

```yaml
steps:
  - uses: actions/checkout@v5

  - uses: actions/setup-python@v6
    with:
      python-version: '3.13'

  - uses: grolston/setup-aws-emulator@v1

  - run: pip install -r requirements.txt
  - run: pytest   # boto3 clients created in tests talk to the emulator
```

For Node.js, the action sets `NODE_EXTRA_CA_CERTS`, so the AWS SDK for JavaScript v3 trusts the emulator certificate. Use path-style addressing for S3:

```js
const s3 = new S3Client({ forcePathStyle: true });
```

For other SDKs, see [SDK notes](#sdk-notes).

### Pin the emulator version

`latest` installs the newest LTS release. Pin a version for reproducible results, and update it deliberately:

```yaml
- uses: grolston/setup-aws-emulator@v1
  with:
    version: '1.0.367'
```

Available versions are listed in [versions.json](https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json) and on the [AWS Emulator releases page](https://github.com/aws/aws-emulator/releases), which also publishes a per-service fidelity score for each release.

### Use the outputs instead of exporting the environment

Set `export-env: false` when only some steps should use the emulator, and pass the outputs explicitly:

```yaml
- id: emulator
  uses: grolston/setup-aws-emulator@v1
  with:
    export-env: 'false'

- name: Integration tests against the emulator
  env:
    AWS_ENDPOINT_URL: ${{ steps.emulator.outputs.endpoint-url }}
    AWS_CA_BUNDLE: ${{ steps.emulator.outputs.ca-file }}
    AWS_SHARED_CREDENTIALS_FILE: ${{ steps.emulator.outputs.credentials-file }}
    AWS_CONFIG_FILE: ${{ steps.emulator.outputs.config-file }}
    AWS_REGION: ${{ steps.emulator.outputs.region }}
  run: ./run-integration-tests.sh
```

### Show the emulator log when tests fail

```yaml
- id: emulator
  uses: grolston/setup-aws-emulator@v1

# ... test steps ...

- name: Emulator log
  if: failure()
  run: cat "${{ steps.emulator.outputs.log-file }}"
```

## Inputs

| Name | Default | Description |
|---|---|---|
| `version` | `latest` | AWS Emulator version to install, such as `1.0.367`, or `latest` for the newest LTS release. |
| `port` | `9297` | Port to listen on (HTTPS, bound to `127.0.0.1`). `0` picks a free port; read it from the `endpoint-url` output. |
| `telemetry` | `off` | `on` to let the emulator send anonymous usage telemetry to AWS. See [Telemetry](#telemetry). |
| `auth` | `on` | `on` requires requests to be signed with the credentials the emulator generates. `off` accepts unsigned requests. |
| `export-env` | `true` | Export the [environment variables](#environment-variables) below to later steps in the job. |
| `verify-signature` | `true` | Verify the package's GPG signature before installing it. |
| `idle-timeout` | | Stop the emulator after this many seconds without an API call (1 to 31536000). Empty keeps it running until the job ends. |
| `startup-timeout` | `60` | Seconds to wait for the emulator to become healthy before failing. |

## Outputs

| Name | Description |
|---|---|
| `version` | The AWS Emulator version that was installed. |
| `endpoint-url` | The emulator endpoint, for example `https://127.0.0.1:9297`. |
| `health-check-url` | The health route. Returns HTTP 200 with body `ok` when the emulator is ready. |
| `ca-file` | Path to the PEM certificate for the emulator's HTTPS endpoint. |
| `truststore-file` | Path to a PKCS12 truststore (no password) with the same certificate, for Java. |
| `credentials-file` | Path to the shared credentials file the emulator generated. Empty when `auth` is `off`. |
| `config-file` | Path to the AWS config file the emulator generated. |
| `region` | The Region the emulator serves (`us-east-1`). |
| `account-id` | The emulator account ID (`000000000000`). |
| `pid` | Process ID of the emulator. |
| `log-file` | Path to the emulator log. |

## Environment variables

With `export-env: true` (the default), these variables are set for every later step in the job:

| Variable | Value |
|---|---|
| `AWS_ENDPOINT_URL` | The emulator endpoint. Used by the AWS CLI and current AWS SDKs for every service. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Credentials generated by the emulator for this run. The secret is masked in logs. |
| `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE` | The credentials and config files the emulator generated. |
| `AWS_CA_BUNDLE` | The emulator certificate, for the AWS CLI, Boto3, and the AWS SDK for Go v2. |
| `NODE_EXTRA_CA_CERTS` | The emulator certificate, for Node.js. Adds to the default trust store rather than replacing it. |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | `us-east-1` |
| `AWS_EC2_METADATA_DISABLED` | `true` |
| `AWS_DISABLE_HOST_PREFIX_INJECTION` | `true` |

If `AWS_SESSION_TOKEN` or `AWS_PROFILE` is already set in the job, the action clears the session token and sets the profile to `default`, with a warning, so no request is signed with real AWS credentials.

## SDK notes

| SDK | What to do |
|---|---|
| AWS CLI v2, Boto3, AWS SDK for Go v2 | Nothing. `AWS_CA_BUNDLE` is set. |
| AWS SDK for JavaScript v3 | Nothing for trust (`NODE_EXTRA_CA_CERTS` is set). Use `forcePathStyle: true` for S3, and `disableHostPrefix: true` if you call APIs that use host prefixes. |
| AWS SDK for Java 2.x | Point the JVM at the truststore: `JAVA_TOOL_OPTIONS: -Djavax.net.ssl.trustStore=${{ steps.emulator.outputs.truststore-file }} -Djavax.net.ssl.trustStoreType=PKCS12` on the test step only. This replaces the JVM trust store, so don't set it for steps that download dependencies. |
| AWS SDK for Rust, .NET | Set `SSL_CERT_FILE` to the `ca-file` output on the test step only. It replaces the system trust store for OpenSSL-based tools. |

Always use `127.0.0.1` rather than `localhost` in the endpoint. With `localhost`, some SDKs put the S3 bucket name in the host name.

## Supported runners

| Runner | Supported |
|---|---|
| `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04` (x64) | Yes |
| `ubuntu-24.04-arm`, `ubuntu-22.04-arm` (arm64) | Yes |
| Self-hosted Linux, x64 or arm64, Debian- or RPM-based, glibc 2.17+ | Yes. Needs `curl`, `gpg` (for signature verification), and root or `sudo`. |
| `macos-*`, `windows-*` | No. AWS Emulator runs natively only on Linux. The action fails with a clear error on these runners. |

## How it works

1. Resolves the version (`latest` is read from the AWS Emulator `versions.json`).
2. Downloads the `.deb` or `.rpm` package for the runner's architecture from `downloads.aws.com`.
3. Verifies the package signature against the AWS publishing key, fingerprint `98BC F336 A3BE 53B7 34E9 67C5 2E5B F49B D940 F624`, as documented in the [AWS Emulator User Guide](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-linux.html). The step fails if the signature is missing, invalid, or made by another key.
4. Installs the package and starts `aws-emulator` in the background, logging to `$RUNNER_TEMP/setup-aws-emulator/emulator.log`.
5. Reads the endpoint and file paths from the emulator's startup line, then polls `/__admin/health` until it returns `ok`.
6. Writes the outputs and, unless disabled, the environment variables.

The emulator runs until the job ends; the runner stops it during job cleanup. Each job gets its own emulator, so jobs never share state.

## Things to know

- **State is in memory.** Everything you create is lost when the emulator stops. To reset state mid-job, run the action again on a different `port`.
- **One account and one Region.** The emulator serves account `000000000000` in `us-east-1`.
- **Fidelity varies by service.** AWS Emulator aims to match AWS behavior, but not every API or behavior is complete. Check the fidelity scores on the [releases page](https://github.com/aws/aws-emulator/releases) and the [known issues](https://github.com/aws/aws-emulator/tree/main/issues). Report emulator gaps to [aws/aws-emulator](https://github.com/aws/aws-emulator/issues), not here.
- **Don't use it to test security.** IAM policies and other security controls are not a substitute for testing against AWS. See [Security in AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/security.html).
- **Keep real credentials out of test jobs.** The action overrides AWS credentials in the environment, but the safest setup is a job that never receives real credentials.

## Telemetry

AWS Emulator collects anonymous usage telemetry by default. **This action turns it off by default** by starting the emulator with `--telemetry off`. To share usage data with AWS and help improve the emulator, set `telemetry: 'on'`. See [Telemetry in AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/telemetry.html) for what is collected.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `AWS Emulator runs natively only on Linux` | Run the job on an Ubuntu runner. |
| `GPG signature verification failed` | The download was corrupted or tampered with. Re-run the job. If it persists, open an issue. |
| `Could not download AWS Emulator <version>` | The version does not exist. Check [versions.json](https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json). |
| `Address already in use` in the emulator log | Another process uses the port. Set a different `port`, or `0`. |
| `AccessDenied: Sign the request with the emulator credentials` | A later step overrode the credentials, for example with `aws-actions/configure-aws-credentials`. Run that action in a different job. |
| `SSL: CERTIFICATE_VERIFY_FAILED` | The client doesn't trust the emulator certificate. See [SDK notes](#sdk-notes). |
| `UnknownService` (HTTP 404) | The emulator could not identify the service. Check the endpoint and that the service is supported. |

## Versioning

This action follows [semantic versioning](https://semver.org/). Use the major tag (`@v1`) to receive compatible updates, or pin a full release tag or commit SHA for maximum stability.

## Contributing

Issues and pull requests are welcome. The [Test workflow](.github/workflows/test.yml) runs the action on x64 and arm64 Ubuntu runners and exercises the AWS CLI, Boto3, and the AWS SDK for JavaScript against the emulator.

## License

[MIT](LICENSE)

AWS Emulator itself is distributed by AWS under its own license; see [aws/aws-emulator](https://github.com/aws/aws-emulator). This project is not affiliated with or endorsed by Amazon Web Services. AWS and Amazon Web Services are trademarks of Amazon.com, Inc. or its affiliates.
