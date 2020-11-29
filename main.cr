require "file_utils"
require "ecr"

# Globals
VIDEO_EXTS  = ["mp4", "mkv"]
PROCESS_DIR = FileUtils.pwd
DEBUG       = true

# Color Terminal
def info(value : String)
  puts "\u001b[35m#{value}\u001b[0m"
end

def debug(value : String)
  puts "\u001b[33m#{value}\u001b[0m" if DEBUG
end

def success(value : String)
  puts "\u001b[32m#{value}\u001b[0m"
end

def error(value : String)
  puts "\u001b[31m#{value}\u001b[0m"
end

# Classes
class Template
  def initialize(@title : String, @chapters : Array(String))
  end

  ECR.def_to_s "template.ecr"
end

class Loudness
  @output_i = "0"
  @output_tp = "0"
  @output_lra = "0"
  @input_i = "0"
  @input_lra = "0"
  @input_tp = "0"
  @input_thresh = "0"
  @target_offset = "0"

  def initialize(@ffmpeg_output : Array(String))
    @output_i = self.get_param("output_i").clamp(-70, -5).to_s
    @output_tp = self.get_param("output_tp").clamp(-9, 0).to_s
    @output_lra = self.get_param("output_lra").clamp(1, 20).to_s
    @input_i = self.get_param("input_i").clamp(-99, 0).to_s
    @input_lra = self.get_param("input_lra").clamp(0, 99).to_s
    @input_tp = self.get_param("input_tp").clamp(-99, 99).to_s
    @input_thresh = self.get_param("input_thresh").clamp(-99, 0).to_s
    @target_offset = self.get_param("target_offset").clamp(-99, 99).to_s
  end

  def get_param(param : String)
    return @ffmpeg_output.select(&.includes?(param)).first.split(":").last.gsub("\"", "").gsub(",", "").strip.to_f
  end

  def to_s(io)
    io << "loudnorm=
    I=#{@output_i}:
    TP=#{@output_tp}:
    LRA=#{@output_lra}:
    measured_I=#{@input_i}:
    measured_LRA=#{@input_lra}:
    measured_TP=#{@input_tp}:
    measured_thresh=#{@input_thresh}:
    offset=#{@target_offset}:
    linear=true:print_format=summary".split("\n").map(&.strip).join("")
  end
end

# Helper functions
def get_video_duration(path : String)
  stdout = IO::Memory.new
  pwd = FileUtils.pwd
  dirname = Path[path].dirname
  filename = Path[path].basename
  FileUtils.cd(dirname)
  Process.run("ffprobe", {
    "-v",
    "quiet",
    "-hide_banner",
    "-i",
    filename,
    "-show_entries",
    "format=duration",
  }, output: stdout, error: stdout)
  output = stdout.to_s
  length = output
    .split("\n")
    .select(&.includes?("duration="))
    .first.split("=")
    .last.to_f.round(2)
  debug output
  FileUtils.cd(pwd)
  return length
end

def pad_zero(value : String | Int)
  "00#{value}".split("").last(2).join("")
end

# Main program
# Process each folder given as process argument
ARGV.each do |folder|
  next if !Dir.exists? folder
  next if !File.directory? folder
  info "Processing #{folder}"

  # Prepare project info
  processed_files = [] of NamedTuple(filename: String, path: String, duration: Float64)
  project_name = Path[folder].basename

  FileUtils.cd(folder)
  FileUtils.mkdir_p("processed")
  processed_files_folder = Path[folder].join("processed").to_s

  # Process each video file in the folder
  Dir.glob("#{folder}/*.{#{VIDEO_EXTS.join(",")}}") do |file|
    filename = Path[file].basename
    dirname = Path[file].dirname
    extension = Path[file].extension
    outpath = Path["processed"].join(filename).to_s

    # Skip existing
    if File.exists?(outpath)
      filename = Path[outpath].basename
      info "Output already exists... #{filename}"
      processed_files << {
        filename: filename,
        path:     Path[folder].join(outpath).to_s,
        duration: get_video_duration(outpath),
      }
      next
    end

    info "Processing #{filename}"

    stdout = IO::Memory.new

    # Get total length
    info "Finding initial video duration..."
    length = get_video_duration(file)

    start_time = 0
    end_time = length.round(2)

    # Detect silence
    info "Detecting silence..."
    Process.run("ffmpeg", {
      "-hide_banner",
      "-i",
      filename,
      "-af",
      "silencedetect=n=-50dB:d=2",
      "-f",
      "null",
      "2>&1",
    }, output: stdout, error: stdout)
    output = stdout.to_s
    output = output
      .split("\n")                          # split lines
      .select(&.includes?("silencedetect")) # grep silencedetect
      .map(&.split("]").last.strip)         # remove prefix
      .in_groups_of(2, "")                  # group start and end time
      .map { |group|
        st = group.first
        et = group.last
        st = st.split(":").last.strip
        et = et.split("|").first.split(":").last.strip
        [st, et].map(&.to_f.round(2))
      } # cleanup time strings

    # Calculate offset start and end positions
    if output.size > 0
      first_silence = output.first
      last_silence = output.last
      stdout.clear

      # Get silent parts and configure time
      debug "First:#{first_silence}\tLast:#{last_silence}\tDuration:#{length}"
      has_intro_silence = first_silence.first < 0.5
      has_outro_silence = (last_silence.last - length).abs < 0.5
      debug "Intro:#{has_intro_silence}\tOutro:#{has_outro_silence}"

      if has_intro_silence
        start_time = (first_silence.last - 1).round(2)
      end
      if has_outro_silence
        end_time = (last_silence.first + 1).round(2)
      end
    end
    debug "Start:#{start_time}\tEnd:#{end_time}"

    # Loudness first-pass
    info "Calculating loudness..."
    Process.run("ffmpeg", {
      "-hide_banner",
      "-i",
      filename,
      "-af",
      "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json",
      "-f",
      "null",
      "-",
    }, output: stdout, error: stdout)
    output = stdout.to_s.split("\n")
    stdout.clear

    # Loudness prepare second pass
    loudnorm = Loudness.new(output).to_s
    debug loudnorm

    # Encode file with loudnorm filter and new duration
    Process.run("ffmpeg", {
      "-y",
      "-hide_banner",
      "-v",
      "quiet",
      "-stats",
      "-i",
      filename,
      "-ss",
      start_time.to_s,
      "-to",
      end_time.to_s,
      "-af",
      loudnorm,
      "-crf",
      "18",
      outpath,
    }, output: stdout, error: stdout)
    output = stdout.to_s
    stdout.clear
    debug output

    processed_files << {
      filename: Path[outpath].basename,
      path:     Path[folder].join(outpath).to_s,
      duration: get_video_duration(outpath),
    }
  end

  # Sort alphabetically
  processed_files.sort! { |f1, f2| f1[:filename] <=> f2[:filename] }
  chapters = [] of NamedTuple(name: String, timestring: String, span: Time::Span)

  # Process chapter information
  processed_files.each { |file|
    # Prepare chapter name (remove extension, suffix and chapter number)
    name = file[:filename]
    namesplit = name.split("-")
    namesplit.shift
    name = namesplit.join("-").strip
    name = Path[name].basename(Path[name].extension)

    # Calculate offset from previous chapter
    seconds = file[:duration].floor.to_i
    milliseconds = ((file[:duration] - seconds) * 1000).to_i
    nanoseconds = milliseconds * 1000000
    span = Time::Span.new(seconds: seconds, nanoseconds: nanoseconds)

    offset = Time::Span.new(seconds: 0)
    offset = chapters.last[:span] if chapters.size > 0

    span += offset

    timestring = "#{pad_zero(offset.minutes)}:#{pad_zero(offset.seconds)}"

    chapters << {
      name:       name,
      timestring: timestring,
      span:       span,
    }
  }

  # Write chapter file
  FileUtils.cd(processed_files_folder)
  chapter_content = chapters.map { |c| "#{c[:timestring]} - #{c[:name]}" }.join("\n")
  File.write("chapters.txt", chapter_content)

  # Write markdown content
  html = Template.new(project_name, chapter_content.split("\n")).to_s
  File.write("markup.html", html)

  # Render project in blender
  FileUtils.cd(PROCESS_DIR)

  render_output = Path[processed_files_folder].join("#{project_name}.mp4")
  if File.exists?(render_output)
    info "Project #{project_name} already rendered. Skipping..."
    next
  end

  current_frame = 0
  total_frames = 0

  # Setup .blend file
  info "Setting up .blend file..."
  Process.run("blender", {
    "base.blend",
    "--background",
    "--python",
    "setup_blend.py",
    "--",
    "input_path=#{processed_files_folder}",
    "output_file=#{project_name}",
  }, error: STDOUT) do |process|
    until process.terminated?
      line = process.output.gets
      if line
        if line.includes? "Total frames:"
          total_frames = line.split(":").last.strip.to_i
        end
        if line.includes? "Blender quit"
          break
        end
      end
    end
  end

  # Render .blend file
  blend_file_path = Path[processed_files_folder].join("#{project_name}.blend")
  video_file_path = Path[processed_files_folder].join("#{project_name}.mp4")
  info "Rendering final file..."
  Process.run("blender", {
    "--background",
    "#{blend_file_path}",
    "-x",
    "1",
    "-a",
  }, error: STDOUT) do |process|
    until process.terminated?
      line = process.output.gets
      if line
        if line.includes? "Append frame"
          frame_no = line.split("frame").last.strip.to_i
          current_frame = frame_no
        end
        if line.includes? "Blender quit"
          break
        end
        print "#{current_frame}/#{total_frames}\r"
      end
    end
  end

  if File.exists? video_file_path
    success "Rendered file: #{video_file_path}"
  else
    error "Failed rendering file: #{video_file_path}"
  end
end
