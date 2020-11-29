require "file_utils"
require "ecr"

class Template
  def initialize(@title : String, @chapters : Array(String))
  end

  ECR.def_to_s "template.ecr"
end

VIDEO_EXTS  = ["mp4", "mkv"]
SUFFIX      = "_loudnorm_nosilence"
PROCESS_DIR = FileUtils.pwd

def get_video_duration(path : String)
  stdout = IO::Memory.new
  pwd = FileUtils.pwd
  dirname = Path[path].dirname
  filename = Path[path].basename
  FileUtils.cd(dirname)
  Process.run("ffprobe", {
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
  FileUtils.cd(pwd)
  return length
end

def pad_zero(value : String | Int)
  "00#{value}".split("").last(2).join("")
end

ARGV.each do |folder|
  next if !Dir.exists? folder
  next if !File.directory? folder
  puts "Processing #{folder}"

  processed_files = [] of NamedTuple(filename: String, path: String, duration: Float64)

  project_name = Path[folder].basename

  FileUtils.cd(folder)
  FileUtils.mkdir_p("processed")
  processed_files_folder = Path[folder].join("processed").to_s

  Dir.glob("#{folder}/*.{#{VIDEO_EXTS.join(",")}}") do |file|
    filename = Path[file].basename
    dirname = Path[file].dirname
    extension = Path[file].extension
    outfilename = filename.gsub(extension, "#{SUFFIX}#{extension}")
    outpath = Path["processed"].join(outfilename).to_s

    puts filename

    if filename.includes? SUFFIX
      puts "File already processed. Skipping..."
      next
    end

    if File.exists?(outpath)
      puts "Output already exists"
      processed_files << {
        filename: Path[outpath].basename,
        path:     Path[folder].join(outpath).to_s,
        duration: get_video_duration(outpath),
      }
      next
    end

    next

    stdout = IO::Memory.new

    # Get total length
    length = get_video_duration(file)

    start_time = 0
    end_time = length.round(2)

    # Detect silence
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

    if output.size > 0
      first_silence = output.first
      last_silence = output.last
      stdout.clear

      # Get silent parts and configure time
      puts "First:#{first_silence}\tLast:#{last_silence}\tDuration:#{length}"
      has_intro_silence = first_silence.first < 0.5
      has_outro_silence = (last_silence.last - length).abs < 0.5
      puts "Intro:#{has_intro_silence}\tOutro:#{has_outro_silence}"

      if has_intro_silence
        start_time = (first_silence.last - 1).round(2)
      end
      if has_outro_silence
        end_time = (last_silence.first + 1).round(2)
      end
    end
    puts "Start:#{start_time}\tEnd:#{end_time}"

    # Loudness first-pass
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
    def get_param(param : String)
      return output.select(&.includes?(param)).first.split(":").last.gsub("\"", "").gsub(",", "").strip
    end

    loudnorm = "loudnorm=
    I=#{get_param("output_i")}:
    TP=#{get_param("output_tp")}:
    LRA=#{get_param("output_lra")}:
    measured_I=#{get_param("input_i")}:
    measured_LRA=#{get_param("input_lra")}:
    measured_TP=#{get_param("input_tp")}:
    measured_thresh=#{get_param("input_thresh")}:
    offset=#{get_param("target_offset")}:
    linear=true:print_format=summary".split("\n").map(&.strip).join("")

    # Remove silence
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
    puts output

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
    name = file[:filename]
    namesplit = name.split("-")
    namesplit.shift
    name = namesplit.join("-").strip
    name = Path[name].basename(Path[name].extension)

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
    puts "Project #{project_name} already rendered. Skipping..."
    next
  end

  Process.run("blender", {
    "base.blend",
    "--background",
    "--python",
    "quickcut.py",
    "--",
    "input_path=#{processed_files_folder}",
    "output_file=#{project_name}.mp4",
  }, output: STDOUT, error: STDOUT)
end
