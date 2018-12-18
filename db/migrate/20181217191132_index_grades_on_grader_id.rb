class IndexGradesOnGraderId < ActiveRecord::Migration[5.2]
  def change
    add_index "grades", ["grader_id"]
  end
end
