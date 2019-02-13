class GradingConflicts < ActiveRecord::Migration[5.2]
  def change
    create_table :grading_conflicts do |t|
      t.integer "course_id", null: false
      t.integer "staff_user_id", null: false
      t.integer "student_user_id", null: false
      t.index ["course_id"], name: "index_grading_conflict_on_course_id"
    end
  end
end
