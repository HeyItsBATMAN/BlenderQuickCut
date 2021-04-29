require "file_utils"
require "ecr"
require "json"

# Globals
VIDEO_EXTS    = ["mp4", "mkv"]
PROCESS_DIR   = FileUtils.pwd
DEBUG         = true
CPU_COUNT     = [1, ((System.cpu_count - 2) / 2).to_i].max
FADE_DURATION = 0.75

info "Using #{CPU_COUNT} workers"

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

# Types
alias ChapterInfo = NamedTuple(name: String, timestring: String, span: Time::Span)
alias ChapterFile = NamedTuple(filename: String, path: String, duration: Float64)

# Classes
class Template
  def initialize(@title : String, @chapters : Array(String))
  end

  ECR.def_to_s "template.ecr"
end

class LoudnormOutput
  include JSON::Serializable

  property input_i : String
  property input_tp : String
  property input_lra : String
  property input_thresh : String
  property output_i : String
  property output_tp : String
  property output_lra : String
  property output_thresh : String
  property normalization_type : String
  property target_offset : String

  def to_s(io)
    io << "loudnorm=
    I=#{@output_i.to_f.clamp(-70, -5)}:
    TP=#{@output_tp.to_f.clamp(-9, 0)}:
    LRA=#{@output_lra.to_f.clamp(1, 20)}:
    measured_I=#{@input_i.to_f.clamp(-99, 0)}:
    measured_LRA=#{@input_lra.to_f.clamp(0, 99)}:
    measured_TP=#{@input_tp.to_f.clamp(-99, 99)}:
    measured_thresh=#{@input_thresh.to_f.clamp(-99, 0)}:
    offset=#{@target_offset.to_f.clamp(-99, 99)}:
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
  args = ["-v", "quiet", "-hide_banner", "-i", filename,
          "-show_entries", "format=duration"]
  Process.run("ffprobe", args, output: stdout, error: stdout)
  output = stdout.to_s.split("\n")
  index = output.index { |line| line.includes?("[FORMAT]") }
  if !index
    raise "Failed to find duration index"
  end
  output = output.skip(index).select(&.includes?("duration=")).first
  length = output.split("=").last.to_f.round(2)
  debug output
  FileUtils.cd(pwd)
  return length
end

def get_loudness_params(path : String)
  stdout = IO::Memory.new
  pwd = FileUtils.pwd
  dirname = Path[path].dirname
  filename = Path[path].basename
  FileUtils.cd(dirname)
  args = ["-hide_banner", "-i", filename, "-af",
          "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"]
  Process.run("ffmpeg", args, output: stdout, error: stdout)
  output = stdout.to_s.split("\n")
  stdout.clear
  index = output.index { |line| line.includes?("Parsed_loudnorm") }
  if !index
    raise "Failed to find loudnorm index"
  end
  FileUtils.cd(pwd)
  return output.skip(index + 1).join("\n")
end

def get_chapter_details(chapter : ChapterFile, last_chapter : ChapterInfo | Nil)
  # Prepare chapter name (remove extension, suffix and chapter number)
  name = chapter[:filename]
  namesplit = name.split("-")
  namesplit.shift
  name = namesplit.join("-").strip
  name = Path[name].basename(Path[name].extension)

  # Calculate offset from previous chapter
  seconds = chapter[:duration].floor.to_i
  milliseconds = ((chapter[:duration] - seconds) * 1000).to_i
  nanoseconds = milliseconds * 1000000
  span = Time::Span.new(seconds: seconds, nanoseconds: nanoseconds)

  offset = Time::Span.new(seconds: 0)
  offset = last_chapter[:span] if last_chapter

  span += offset

  timestring = "#{pad_zero(offset.minutes)}:#{pad_zero(offset.seconds)}"

  return {
    name:       name,
    timestring: timestring,
    span:       span,
  }
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
    args = ["-hide_banner", "-i", filename, "-af",
            "silencedetect=n=-50dB:d=2", "-f", "null", "2>&1"]
    Process.run("ffmpeg", args, output: stdout, error: stdout)
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
    output = get_loudness_params(file)
    # Loudness prepare second pass
    loudnorm = LoudnormOutput.from_json(%(#{output})).to_s
    debug loudnorm

    audio_filters = [loudnorm]
    # Noise reduction
    audio_filters << "afftdn"

    # Fade in and out of video
    video_filters = [
      "fade=t=in:st=#{start_time}:d=#{FADE_DURATION}",
      "fade=t=out:st=#{end_time - FADE_DURATION}:d=#{FADE_DURATION}",
    ]
    audio_filters << "afade=t=in:st=#{start_time}:d=#{FADE_DURATION}"
    audio_filters << "afade=t=out:st=#{end_time - FADE_DURATION}:d=#{FADE_DURATION}"

    debug audio_filters.join(",")
    debug video_filters.join(",")

    # Encode file with audio filters and new duration
    info "Encoding file #{filename}"
    args = ["-y", "-hide_banner", "-v", "quiet", "-stats",
            "-i", filename,
            "-ss", start_time.to_s,
            "-to", end_time.to_s,
            "-af", audio_filters.join(","),
            "-vf", video_filters.join(","),
            "-crf", "18",
            outpath]
    Process.run("ffmpeg", args, error: STDOUT) do |process|
      until process.terminated?
        line = process.output.gets
        if line
          if line.includes? "frame="
            line = "#{line.strip}\r"
            print line
          end
        else
          puts ""
          print "\r"
          break
        end
      end
    end

    processed_files << {
      filename: Path[outpath].basename,
      path:     Path[folder].join(outpath).to_s,
      duration: get_video_duration(outpath),
    }
  end

  # Sort alphabetically
  processed_files.sort! { |f1, f2| f1[:filename] <=> f2[:filename] }

  # Process chapter information
  chapters = [] of ChapterInfo
  processed_files.each { |file|
    chapters << get_chapter_details(file, chapters.last?)
  }

  # Write chapter file
  FileUtils.cd(processed_files_folder)
  chapter_content = chapters.map { |c| "#{c[:timestring]} - #{c[:name]}" }.join("\n")
  File.write("chapters.txt", chapter_content)

  # Write markdown content
  html = Template.new(project_name, chapter_content.split("\n")).to_s
  File.write("markup.html", html)

  # Merge video files
  render_output = Path[processed_files_folder].join("#{project_name}.mp4")
  if File.exists?(render_output)
    info "Project #{project_name} already rendered. Skipping..."
    next
  end

  File.write("list.txt", processed_files.map { |file|
    cleaned_name = file[:filename].gsub(" ", "\\ ")
    "file ./#{cleaned_name}"
  }.join("\n"))

  info "Merging video files..."
  args = ["-hide_banner", "-v", "quiet", "-stats",
          "-f", "concat", "-safe", "0", "-i", "list.txt",
          "-crf", "20", "#{project_name}.mp4"]
  Process.run("ffmpeg", args, output: STDOUT, error: STDOUT)

  if File.exists? render_output
    success "Rendered file: #{render_output}"
  else
    error "Failed rendering file: #{render_output}"
  end
end
