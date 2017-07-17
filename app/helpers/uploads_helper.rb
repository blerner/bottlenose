require 'fileutils'
require 'audit'
require 'open3'

module UploadsHelper
  class Postprocessor
    private
    PROCS = {}
    public
    def self.create_handler(name, &block)
      name = name.to_s
      # slight shenanigans to access the private :define_method and :remove_method methods
      # but this avoids the icky "warning: tried to create Proc object without a block"
      PROCS.class.send(:define_method, :temp_method, &block)
      PROCS[name] = PROCS.class.instance_method(:temp_method).bind(PROCS)
      PROCS.class.send(:remove_method, :temp_method)
    end
    def self.alias_handler(new_name, old_name)
      new_name = new_name.to_s
      old_name = old_name.to_s
      PROCS[new_name] = PROCS[old_name]
    end

    def self.process(extracted_path, f)
      ext = File.extname(f)[1..-1]
      PROCS[ext]&.call(extracted_path, f)
    end

    create_handler :rkt do |extracted_path, f|
      embeds = extracted_path.dirname.join("embedded")
      embeds.mkpath
      output, err, status = Open3.capture3("xvfb-run", "-a", "--server-num", "1",
                                           "racket", Rails.root.join("lib/assets/render-racket.rkt").to_s,
                                           "-e", embeds.to_s,
                                           "-o", f + "ext",
                                           f)
      if status.success?
        contents = File.read(f + "ext")
        File.open(f, "w") do |f|
          f.write contents.gsub(Upload.base_upload_dir.to_s, "/files")
        end
        FileUtils.rm(f + "ext")
        Audit.log "Successfully processed #{f}"
        return true
      else
        FileUtils.rm (f + "ext"), force: true
        Audit.log <<ERROR
================================
Problem processing #{f}:
Status: #{status}
Error: #{err}
Output: #{output}
================================
ERROR
        return false
      end
    end
    alias_handler :ss, :rkt
  end
end
