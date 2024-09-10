class JsonParser
  attr_reader :json, :test_count, :tests, :commentary, :passed_count, :time_taken, :output, :errors
  attr_reader :filename
  attr_reader :score, :max_score

  def initialize(json, filename=nil)
    @filename = filename
    @json = json
    @test_count = json['tests']&.count
    @output = json['output']
    @errors = json['errors']
    @tests = json['tests']&.map&.with_index do |t, num|
      t = t.clone
      weight = t.delete('weight') || t.delete('max_score') || t.delete('max-score')
      score = t.delete('score')
      passed = t.delete('passed')
      if weight.nil? && passed.nil?
        {
          num: num,
          score: t['score'].to_f,
          **t.symbolize_keys
        }
      else
        weight = weight.to_f if weight.present?
        passed = (score == weight) if passed.nil?
        {
          num: num,
          weight: weight,
          passed: passed,
          score: score,
          **t.symbolize_keys
        }
      end
    end
    @passed_count = @tests&.count { |t| t[:passed] } || 0
    @score = @json['score'] || 0
    @max_score = @json['max-score'] || 0
  end
end
