// Exercises the AWS SDK for JavaScript v3 against the emulator.
//
// The endpoint, credentials, region, and CA certificate (NODE_EXTRA_CA_CERTS)
// all come from the environment exported by the action.

const { randomUUID } = require("node:crypto");
const { S3Client, CreateBucketCommand, PutObjectCommand, GetObjectCommand } = require("@aws-sdk/client-s3");
const { STSClient, GetCallerIdentityCommand } = require("@aws-sdk/client-sts");

async function main() {
  const identity = await new STSClient({}).send(new GetCallerIdentityCommand({}));
  if (identity.Account !== "000000000000") {
    throw new Error(`Unexpected account: ${identity.Account}`);
  }

  // Path-style addressing keeps the bucket name out of the host name.
  const s3 = new S3Client({ forcePathStyle: true });
  const bucket = `node-bucket-${randomUUID().slice(0, 8)}`;
  await s3.send(new CreateBucketCommand({ Bucket: bucket }));
  await s3.send(new PutObjectCommand({ Bucket: bucket, Key: "hello.txt", Body: "hello" }));
  const object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: "hello.txt" }));
  const body = await object.Body.transformToString();
  if (body !== "hello") {
    throw new Error(`Unexpected object body: ${body}`);
  }

  console.log(`AWS SDK for JavaScript checks passed against ${process.env.AWS_ENDPOINT_URL}.`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
