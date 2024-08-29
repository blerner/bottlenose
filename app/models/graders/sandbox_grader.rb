require 'json'
require 'securerandom'
require 'tap_parser'
require 'audit'
require 'container'

class SandboxGrader < Grader
  after_initialize :load_sandbox_params
  before_validation :set_sandbox_params
  validate :proper_configuration

  RESPONSE_TYPES = [
    ["List of outputs", "simple_list"],
    ["Plain text", "plaintext"],
    ["Inline comments", "inline_comments"],
    ["Checker tests", "checker_tests"],
    ["xUnit tests", "xunit_tests"],
    ["Examplar", "examplar"]
  ]
  
  def load_sandbox_params
    return if new_record?
    data = JSON.parse(self.params).deep_symbolize_keys
    self.display_name = data[:display_name]
    self.response_type = data[:response_type]
  end
  def set_sandbox_params
    self.params = {
      display_name: self.display_name,
      response_type: self.response_type
    }.to_json
  end
  def proper_configuration
    if self.upload.nil?
      add_error("Upload cannot be nil")
    else
      if self.display_name.blank?
        add_error("Display name cannot be blank")
      end
      if self.response_type.blank?
        add_error("Response type cannot be blank")
      end
    end
    return if upload.nil?
    begin
      entries = self.upload.upload_entries(with_contents: true)
      if entries["Dockerfile"].blank?
        add_error("No Dockerfile provided")
      end
      if entries["grading_script.json"].blank?
        add_error("No grading_script.json provided")
      # TODO: when the validation endpoint works, try this again.
      # else
      #   orca_url = Grader.orca_config['site_url'][Rails.env]
      #   body, status_code = post_image_request_with_retry(
      #     URI.parse("#{orca_url}/api/v1/validate_grading_script"),
      #     JSON.parse(entries["grading_script.json"])
      #   )
      #   unless body&.dig('errors').blank?
      #     add_error("Grading script is ill-formed:\n#{body['errors'].join('\n')}")
      #   end
      end
    rescue Exception => e
      e_msg = e.to_s
      e_msg = e_msg.dump[1...-1] unless e_msg.is_utf8?
      add_error("Could not read upload: #{e_msg}")
    end
  end
  
  def autograde?
    true
  end

  def display_type
    self.display_name || "Sandboxed Script"
  end

  def to_s
    if self.upload
      "#{self.avail_score} points: Run #{self.display_type}, using #{self.upload.file_name}"
    else
      "#{self.avail_score} points: Run #{self.display_type}"
    end
  end

  protected

  def get_grading_script(sub)
    JSON.load(File.open(self.upload.extracted_files.to_h {|v| [v[:path], v[:full_path]]}["grading_script.json"]))
  end

  def generate_files_hash(sub)
    files = {
      submission: {
        url: sub.upload.url,
        mime_type: sub.upload.read_metadata[:mimetype],
        should_replace_paths: false
      },
      grader: {
        url: self.upload.url,
        mime_type: self.upload.read_metadata[:mimetype],
        should_replace_paths: false
      }
    }
  end

  def postprocess_orca_response(grade, response)
    sub = grade.submission
    prefix = "Assignment #{assignment.id}, submission #{sub.id}"
    if response['errors'].present?
      grade.score = 0
      grade.out_of = self.avail_score
      grade.updated_at = DateTime.current
      grade.available = true
      grade.save!
      InlineComment.transaction do
        InlineComment.where(submission: sub, grade: grade).destroy_all
        InlineComment.create!(
          submission: sub,
          title: "Errors",
          filename: Upload.upload_path_for(sub.upload.extracted_path.to_s),
          line: 0,
          grade: grade,
          user: nil,
          label: "general",
          severity: InlineComment::severities["error"],
          weight: self.avail_score,
          comment: response['errors'].join('\n'),
          suppressed: false)
      end
    else
      output = response['output']
      output.gsub!("$EXTRACTED/submission", sub.upload.extracted_path)
      begin
        case self.response_type
        when "inline_comments", "checker_tests", "xunit_tests", "examplar"
          tap = TapParser.new(output)
          Audit.log("#{prefix}: #{self.response_type} results: Tap: #{tap.points_earned}")
          record_tap_as_comments(grade, tap, sub)
        when "simple_list"
          json = JSON.parse(output)
          Audit.log("#{prefix}: #{self.response_type} results: Tap: #{json['score']} / #{json['max-score']}")
          grade.score = json['score'].to_f
          grade.out_of = json['max-score']&.to_f || self.avail_score
          grade.updated_at = DateTime.current
          grade.available = true
          grade.save!
          InlineComment.transaction do
            InlincComment.where(submission: sub, grade: grade).destroy_all
            ics = json['tests'].map do |t|
              InlineComment.new(
                submission: sub,
                title: t['name'] || t['comment'] || '',
                filename: Upload.upload_path_for(t['filename'] || sub.upload.extracted_path.to_s),
                line: t['line'].to_i || 0,
                grade: grade,
                user: nil,
                label: 'general',
                comment: t['output'],
                weight: t['score'].to_f,
                suppressed: false)
            end
            InlineComment.import ics
          end
        when "plaintext"
        end
      rescue Exception => e
        Audit.log("#{prefix}: #{self.response_type} error: #{e}")
        record_compile_error(sub, grade)
      end
    end
  end
  
  def do_grading(assignment, sub)
    # Nothing to do, since Orca will handle it!
  end

  def dockerfile_path
    self.upload.extracted_files.to_h {|v| [v[:path], v[:full_path]]}["Dockerfile"]
  end

  def dockerfile_sha_sum
    Digest::SHA256.hexdigest(File.read(dockerfile_path))
  end

end
