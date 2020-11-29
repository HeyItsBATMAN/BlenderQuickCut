# BlenderQuickCut

## Description

A set of tools combined in a way to process video folders to:
- cut silence at the beginning and the end of videos
- normalize the audio of videos
- combine all the videos with cross-fades
- prepare a list of chapters using the filenames
- prepare an HTML file with simple markup containing video related info

## Why?

Since the beginning of the pandemic, I've "held" my lessons using videos.
While the speed of recording videos increased, I still spend a lot of time doing repetitive tasks to prepare, cut and render the videos.
This is my attempt of automating the repetitive tasks.

## Requirements

- FFmpeg
- Blender
- Crystal-Lang

At the time of writing I'm using FFmpeg version 4.3.1 and Blender version 2.91

## Usage

Compile the main program, e.g.
```crystal build --release main.cr```

Execute the program against a folder
```./main -- "/path/to/some/folder/containing/videos/"```

## Video naming

Before running the program, a folder containing videos should have the videos named like "Chapter No. -  Chapter Name", e.g. "01 - Introduction", "02 - Main Issue"

## Project naming

The Project name will be taken from the folder name.

If your path is: "/path/to/FooBar/" your project will be named "FooBar"
