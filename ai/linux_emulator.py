from gradio_client import Client

client = Client("WillemVH/LinuxEmulator")
result = client.predict(
		command="Hello!!",
		api_name="/execute_command"
)
print(result)
