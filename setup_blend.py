# Author: Kai Niebes <kai.niebes@outlook.com>
# Description:
# Import video files to the blender sequence editor from a folder,
# line them all up and add fade-in-out.
# Check the final .blend to see if everything worked
# Usage:
# blender --background --python setup_blend.py -- input_path="/path/to/folder" output_file="example"

import bpy
import sys
import os
from glob import glob

# Helper functions
video_exts = ['mp4', 'mkv']
def is_video(video_filename):
  for ext in video_exts:
    if video_filename.endswith(ext):
      return True
  return False

# Parse arguments
args = sys.argv[sys.argv.index("--") + 1:]
opts = {}
for arg in args:
  key, value = arg.split("=")
  opts[key] = value

if not opts.get("input_path"):
  raise "No input path given"

if not opts.get("output_file"):
  raise "No output file given"

# Override context
override = bpy.context.copy()
override['selected_objects'] = list(bpy.context.scene.objects)
bpy.ops.object.delete(override)

# Execution context
bpy.ops.object.collection_instance_add('INVOKE_AREA')
for window in bpy.context.window_manager.windows:
  screen = window.screen

  for area in screen.areas:
    if area.type == 'SEQUENCE_EDITOR':
      override = {'window': window, 'screen': screen, 'area': area}
      bpy.ops.screen.screen_full_area(override)
      break

# Get input files
input_path = opts.get("input_path")
input_files = glob(input_path + '/*', recursive = False)
input_files = list(filter(is_video, input_files))
input_files = sorted(input_files)
print(input_files)

# Add files to sequence, add fade
for filepath in input_files:
  directory = os.path.dirname(filepath)
  filename = os.path.basename(filepath)
  files = [{"name": filename,"name": filename}]

  frame_start = 1
  if len(bpy.context.sequences) > 0:
    frame_start = max(seq.frame_final_end for seq in bpy.context.sequences)

  bpy.ops.sequencer.select_all(action='DESELECT')
  bpy.ops.sequencer.movie_strip_add(filepath=filepath, directory=directory, frame_start=frame_start, channel=1, files=files)
  bpy.ops.sequencer.meta_make()
  bpy.ops.sequencer.fades_add(type='IN_OUT')

# Set final frame
final_frame = max(seq.frame_final_end for seq in bpy.context.sequences)
bpy.context.scene.frame_current = final_frame
bpy.ops.anim.end_frame_set()
print("Total frames: {}".format(final_frame))

# Render file
output_directory = input_path
output_filename = opts.get("output_file")
mp4 = output_filename + ".mp4"
blend = output_filename + ".blend"
blend_output_path = os.path.join(output_directory, blend)
bpy.context.scene.render.filepath = os.path.join(output_directory, mp4)

if os.path.exists(blend_output_path):
  os.remove(blend_output_path)
bpy.ops.wm.save_as_mainfile(filepath=blend_output_path)
