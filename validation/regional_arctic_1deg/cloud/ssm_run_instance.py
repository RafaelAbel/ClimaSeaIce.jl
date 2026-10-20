import argparse
import pathlib
import time

import botocore.session


parser = argparse.ArgumentParser()
parser.add_argument("instance_id")
parser.add_argument("script", type=pathlib.Path)
parser.add_argument("--timeout", type=int, default=600)
args = parser.parse_args()

client = botocore.session.get_session().create_client("ssm", region_name="eu-central-1")
sent = client.send_command(
    InstanceIds=[args.instance_id],
    DocumentName="AWS-RunShellScript",
    Parameters={"commands": [args.script.read_text()],
                "executionTimeout": [str(args.timeout)]},
)
command_id = sent["Command"]["CommandId"]
print("command_id:", command_id, flush=True)
while True:
    time.sleep(2)
    result = client.get_command_invocation(CommandId=command_id,
                                           InstanceId=args.instance_id)
    if result["Status"] not in {"Pending", "InProgress", "Delayed"}:
        print("status:", result["Status"])
        print(result.get("StandardOutputContent", ""))
        print(result.get("StandardErrorContent", ""))
        raise SystemExit(0 if result["Status"] == "Success" else 1)
