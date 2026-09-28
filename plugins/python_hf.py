import sys
from gradio_client import Client

client = Client("WillemVH/LinuxEmulator", verbose=False)

command = sys.stdin.read().strip()

if not command:
    sys.exit(0)

result = client.predict(
    command=command,
    api_name="/execute_command"
)

print(result, end="")

