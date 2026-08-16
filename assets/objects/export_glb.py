import bpy, sys

argv = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.export_scene.gltf(filepath=argv[0], export_format="GLB")

