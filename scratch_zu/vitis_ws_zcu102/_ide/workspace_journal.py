# 2026-10-26T15:25:31.862488300
import vitis

client = vitis.create_client()
client.set_workspace(path="vitis_ws_zcu102")

vitis.dispose()

