require 'open3'
require 'tap_parser'
require 'audit'
require 'net/http'
require 'digest'
require 'securerandom'
require 'java_grader_file_processor'

class JunitGrader < Grader
  after_initialize :load_junit_params
  after_save :process_grader_zip
  before_validation :set_junit_params
  validate :proper_configuration

  @@resource_files = {
    "lib/assets/annotations.jar": ["annotations-jar", "application/zip", false],
    "lib/assets/junit-4.13.2.jar": ["junit-jar", "application/zip", false],
    "lib/assets/junit-tap.jar": ["junit-tap-jar", "application/zip", false],
    "lib/assets/hamcrest-core-1.3.jar": ["hamcrest-jar", "application/zip", false]
  }

  def self.dockerfile_path
    Rails.root.join 'lib/assets/dockerfiles/java-grader.Dockerfile'
  end

  def self.dockerfile_sha_sum
    Digest::SHA256.hexdigest(File.read(JunitGrader.dockerfile_path))
  end

  def dockerfile_sha_sum
    JunitGrader.dockerfile_sha_sum
  end

  def dockerfile_path
    JunitGrader.dockerfile_path
  end

  def autograde?
    true
  end

  def display_type
    if self.test_class&.downcase.include?("examplar")
      "Examplar results"
    else
      "JUnit Tests"
    end
  end

  def to_s
    if self.upload
      filename = self.upload.file_name
    else
      filename = "<no file>"
    end
    "#{self.avail_score} points: Run JUnit tests in #{test_class} from #{filename} " +
      "(with default timeout #{test_timeout}), " +
      "and show #{pluralize(errors_to_show, 'failed test')}"
  end

  def export_data
    export_tap_data
  end
  def export_data_schema
    "junit_export_schema"
  end
  def import_data(who_grades, file)
    import_tap_data(who_grades, file) do |g, raw_tap, sub|
      if File.extname(g.grading_output_path) == ".tap"
        tap = TapParser.new(raw_tap)
        g.score = tap.points_earned
        g.out_of = tap.points_available
      else
        g.score = 0
        g.out_of = self.avail_score
      end
      g.updated_at = DateTime.current
      g.available = true
    end
  end
  def import_data_schema
    "junit_import_schema"
  end

  def check_for_malformed_submission(upload)
    errors = []
    entries = upload.upload_entries
    if entries["src"] && !entries["test"]
      errors << "Having a src/ directory requires having a test/ directory also"
    end
    if entries["test"] && !entries["src"]
      errors << "Having a test/ directory requires having a src/ directory also"
    end
    if entries.size == 1
      rootName, rootEntry = entries.first
      if rootEntry == true
        # nothing to do; it's just one file
      elsif rootName != "src" && rootName != "test"
        errors << "Make sure your submission is directly at the root of your zip, not nested within another directory (#{rootName}/)"
      end
    end
    if self.test_class&.downcase.include?("examplar")
      if entries["src"].is_a?(Hash)
        java_files = search_for(entries["src"], "src") {|f| f.ends_with? ".java" }
        if java_files.size > 0
          errors << "Make sure not to submit any src/ files for Examplar assignments (#{java_files.to_sentence})"
        end
      end
    end
    errors
  end

  protected
  def search_for(entries, path, &block)
    entries.map do |k, v|
      filename = "#{path}#{File::SEPARATOR}#{k}"
      if v == true
        if block.call(filename)
          [filename]
        else
          []
        end
      else
        search_for(v, filename, &block)
      end
    end.flatten
  end

  def load_junit_params
    return if new_record?
    testClass, errorsToShow, testTimeout = self.params.to_s.split(";")
    self.test_class = testClass
    self.errors_to_show = errorsToShow.to_i
    self.test_timeout = (testTimeout || Grader::DEFAULT_TEST_TIMEOUT).to_i
  end
  def set_junit_params
    self.params = "#{self.test_class};#{self.errors_to_show};#{self.test_timeout}"
  end

  def do_grading(assignment, sub)
    g = self.grade_for sub
    Dir.mktmpdir("grade-#{sub.id}-#{g.id}_") do |build_dir|
      @build_dir = build_dir
      begin
        run_build_produce_problems assignment, sub, include_dirtree: !self.test_class.downcase.include?("examplar") do |prefix, any_problems, details|
          if any_problems
            g.grading_output_path = details.path
            g.score = 0
            g.out_of = self.avail_score
            g.updated_at = DateTime.current
            g.available = true
            g.save!
          else
            timeout = Grader::DEFAULT_GRADING_TIMEOUT
            # If the professor supplied a per-test timeout, then we can relax our overall timeout a bit
            if self.test_timeout then timeout = timeout * 5 end
            run_command_produce_tap assignment, sub, timeout: timeout do |prefix, err, g, tap|
              if tap
                g.score = tap.points_earned
                g.out_of = tap.points_available
                g.updated_at = DateTime.current
                g.available = true
                g.save!
                Audit.log("#{prefix}: Tests give raw score of #{g.score} / #{g.out_of}")
              else
                if err[:output]
                  details.write("Test output: (exit status #{err[:status] || 'unknown'})\n")
                  details.write(err[:output])
                end
                if err[:err]
                  details.write("Test errored: (exit status #{err[:status] || 'unknown'})\n")
                  details.write(err[:err])
                end
                if err[:timed_out]
                  details.write("Running tests timed out after #{self.test_timeout} seconds")
                end
                Audit.log("#{prefix}: Errors prevented grading; giving a 0")
                g.grading_output_path = details.path
                g.score = 0
                g.out_of = self.avail_score
                g.updated_at = DateTime.current
                g.available = true
                g.save!
              end
            end
          end
        end
      rescue Exception => e
        Audit.log("Assignment #{assignment.id}, submission #{sub.id}: Errors prevented grading; giving a 0: #{e} at #{e.backtrace.join("\n")}")
        g.score = 0
        g.out_of = self.avail_score
        g.updated_at = DateTime.current
        g.available = true
        g.save!
      end
    end
  end

  def get_extraction_arguments(assignment, sub)
    [
      @build_dir,
      self.upload.extracted_path,
      sub.upload.extracted_path,
      [
        Rails.root.join("lib/assets/annotations.jar"),
        Rails.root.join("lib/assets/junit-4.13.2.jar"),
        Rails.root.join("lib/assets/junit-tap.jar"),
        Rails.root.join("lib/assets/hamcrest-core-1.3.jar")
      ]
    ]
  end

  def get_build_arguments(assignment, sub)
    test_classes = self.test_class.gsub(".", "/").split(" ").map{|f| ["#{@build_dir}/#{f}.java", true]}.to_h
    test_files, student_files = Dir.glob("#{@build_dir}/**/*.java").reject do |f|
      Pathname.new(f).ascend.any?{|c| c.basename.to_s == "__MACOSX" || c.basename.to_s == ".DS_STORE"}
    end.partition{|f| test_classes[f]}
    files = test_files + student_files
    File.open("#{@build_dir}/compile_list.txt", "w") do |compile_list|
      files.each do |f| compile_list.puts(f.gsub("#{@build_dir}/", "")) end
    end
    [
      "details.log",
      {},
      [
        ["cat", "compile_list.txt"],
        ["javac", "-cp", "junit-4.13.2.jar:junit-tap.jar:hamcrest-core-1.3.jar:annotations.jar:.:./*",
         "@compile_list.txt"]
      ],
      {},
      @build_dir
    ]
  end

  def get_command_arguments(assignment, sub)
    test_class_args = self.test_class.split(" ")
    test_class_args.unshift "edu.neu.TAPRunner" unless (test_class_args[0] == "examplar.Main")
    [
      "junit.tap",
      {},
      ["java", "-cp", "junit-4.13.2.jar:junit-tap.jar:hamcrest-core-1.3.jar:annotations.jar:.:./*",
       *test_class_args,
       "-timeout", self.test_timeout.to_s],
      {},
      @build_dir
    ]
  end

  def recompute_grades
    # nothing to do:
    # we already compute the score here based on the TAP output
  end

  def proper_configuration
    if self.upload.nil?
      add_error("Upload cannot be nil")
    else
      if self.test_class.blank?
        add_error("Test class cannot be blank")
      end
      if self.errors_to_show.blank?
        add_error("Errors to show cannot be blank")
      end
      if self.test_timeout.blank?
        add_error("Default test timeout cannot be blank")
      end
    end
    return if self.upload.nil? || self.test_class.blank?
    begin
      entries = self.upload.upload_entries
      if entries["#{self.test_class}.java"]
        # ok, nothing to do
      elsif entries["starter"] && entries["testing"]
        ok = true
        if entries["starter"].size > 0 && !(entries["starter"]["src"] && entries["starter"]["test"])
          add_error("The starter/ directory does not contain src/ and test/ subdirectories")
          ok = false
        end
        if !(entries["testing"]["src"] && entries["testing"]["test"])
          add_error("The testing/ directory does not contain src/ and test/ subdirectories")
          ok = false
        end
        if ok
          self.test_class.split.each do |tc|
            next if (tc.starts_with?("-") || (Float(tc) rescue false))
            if !classNamed(entries["testing"]["test"], tc)
              add_error("There is no #{tc} file (either .java or .class) to match the specified test class")
            end
          end
          if classNamed(entries["testing"]["test"], "GradingSandbox")
            add_error("There must not be a class named GradingSandbox")
          end
        end
      else
        ok = true
        if !(entries["src"] && entries["test"])
          add_error("The archive does not contain src/ and test/ subdirectories")
          ok = false
        end
        if ok && !self.test_class.downcase.include?("examplar")
          self.test_class.split.each do |tc|
            next if (tc.starts_with?("-") || (Float(tc) rescue false))
            if !classNamed(entries["test"], tc)
              add_error("There is no #{tc} file (either .java or .class) to match the specified test class")
            end
          end
          if classNamed(entries["test"], "GradingSandbox")
            add_error("There must not be a class named GradingSandbox")
          end
        end
      end
    rescue Exception => e
      e_msg = e.to_s
      e_msg = e_msg.dump[1...-1] unless e_msg.is_utf8?
      add_error("Could not read upload: #{e_msg}")
    end
  end

  # Orca grading job methods.

  def generate_files_hash(sub)
    files = {
      submission: {
        url: sub.upload.url,
        mime_type: guess_orca_mimetype(sub.upload),
        should_replace_paths: false
      }
    }
    grader_zip_paths.each do |key, path|
      files[key] = {
        url: Settings["site_url"] + Upload.upload_path_for(path),
        mime_type: "application/zip",
        should_replace_paths: false
      }
    end

    @@resource_files.each do |file_path, (files_key, mime, should_replace_paths)|
      files[files_key] = {
        url: "#{Settings['site_url']}/resources/#{file_path.to_s.gsub('lib/assets/', '')}",
        mime_type: mime,
        should_replace_paths: should_replace_paths
      }
    end
    files
  end

  def get_grading_script(sub)
    # NOTE: the JSON script from lib/assets contains everything that we know to be static, i.e., the build steps.
    # A JUnit Grader's test classes are dynamic, thus why we load in the partial script and
    # append the tap runner at the end.
    build_script = JSON.load(File.open(Rails.root.join("lib/assets/orca-grading-scripts/junit_grader.json")))
    # NOTE(Ben): Temporary fix to patch in Examplar support here, without duplicating code
    cmdargs = get_command_arguments(nil, nil)
    cmd = cmdargs[2]
    build_script << {
      cmd: cmd,
      on_complete: "output",
      timeout: 360,
      working_dir: "$BUILD"
    }
  end

  def save_uploads
    super
  end

  def grader_zip_paths
    [] unless File.directory? upload.extracted_path
    keys_to_paths = {
      'starter': File.join(upload.extracted_path, 'starter.zip'),
      'testing': File.join(upload.extracted_path, 'testing.zip')
    }
    keys_to_paths.select { |_, p| File.exist? p }
  end

  def process_grader_zip
    JavaGraderFileProcessor.process_zip(self.upload)
  end

  def classNamed(dict, name)
    sources = name.split(".")
    sources[-1] += "\.java"
    classes = name.split(".")
    classes[-1] += ".class"
    return dict.dig(*sources) || dict.dig(*classes)
  end
end
