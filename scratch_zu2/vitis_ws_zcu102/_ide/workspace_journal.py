# 2026-10-26T23:45:47.592212
import vitis

client = vitis.create_client()
client.set_workspace(path="vitis_ws_zcu102")

vitis.dispose()

