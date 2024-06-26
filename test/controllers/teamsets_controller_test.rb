require 'test_helper'

class TeamsetsControllerTest < ActionController::TestCase
  setup do
    @team = create(:team)
    @fred = create(:user)
    r = create(:registration, user: @fred, course: @team.course, new_sections: [@team.course.sections.first],
               role:  Registration::roles[:professor])
    r.save_sections

    mreg = create(:registration, course: @team.course, new_sections: [@team.course.sections.first])
    mreg.save_sections
    @mark = mreg.user
    jreg = create(:registration, course: @team.course, new_sections: [@team.course.sections.first])
    jreg.save_sections
    @jane = jreg.user
    greg = create(:registration, course: @team.course, new_sections: [@team.course.sections.first])
    greg.save_sections
    @greg = greg.user

    @largeCourse = create(:course)
    @largeTs = create(:teamset, course: @largeCourse)
    @manyUsers = (1..30).map do |n| create(:user) end
    @manyUsers.each do |u|
      r = Registration.create(user: u, course: @largeCourse, new_sections: [@largeCourse.sections.first],
                          role: Registration::roles[:student], show_in_lists: true)
      r.save_sections
      r
    end
    Registration.create(user: @fred, course: @largeCourse, new_sections: [@largeCourse.sections.first],
                        role: Registration::roles[:professor], show_in_lists: true)
      .save_sections
  end

  test "accepting invalid team should not destroy request" do
    teamset = @team.teamset
    mark_jane_team = Team.new(course: teamset.course, teamset: teamset, start_date: DateTime.current, end_date: nil)
    mark_jane_team.users = [@mark, @jane]
    mark_jane_team.save!
    req1 = TeamRequest.create(teamset: teamset, user: @mark,
                             partner_names: [@mark.username, @jane.username, @greg.username].join(';'))
    req1.save!
    req2 = TeamRequest.create(teamset: teamset, user: @jane,
                             partner_names: [@mark.username, @jane.username, @greg.username].join(';'))
    req2.save!
    req3 = TeamRequest.create(teamset: teamset, user: @greg,
                             partner_names: [@mark.username, @jane.username, @greg.username].join(';'))
    req3.save!
    sign_in @fred
    assert_no_difference('Team.count') do
      delete :accept_request, params: {
               course_id: @team.course_id,
               id: teamset.id,
               custom: {
                 start_date: DateTime.current,
                 users: [@mark.id, @jane.id, @greg.id]
               }
             }
      assert_response 400
    end
    [req1, req2, req3].each do |req|
      assert_equal req, TeamRequest.find(req.id)
    end
    assert_equal "Could not create team: #{@mark.username} and #{@jane.username} are already in an active team",
                 assigns(:teamset).errors.full_messages.to_sentence
  end
  
  test "should get index" do
    sign_in @fred
    get :index, params: { course_id: @team.course, teamset_id: @ts1 }
    assert_response :success
    assert_not_nil assigns(:teams)
  end

  test "should get edit" do
    sign_in @fred
    get :edit, params: { id: @team.teamset, course_id: @team.course }
    assert_response :success
  end

  test "should create team" do
    sign_in @fred

    assert_difference('Team.count') do
      patch :update, params: {
              course_id: @team.course,
              id: @team.teamset_id,
              single: { start_date: @team.start_date },
              users: [ @mark.id, @jane.id, @greg.id ] }
    end

    assert_response :redirect
    assert_equal 3, assigns(:team).users.count
  end

  test "should clone teamset" do
    sign_in @fred
    @largeTs.randomize(3, "course", Date.current)
    @largeTs.dissolve_all(DateTime.current)
    @largeTs.randomize(6, "course", Date.current)
    # Create 15 teams, only five of which are active
    @ts2 = create(:teamset, course: @largeCourse)
    assert_difference('Team.count', 5) do
      patch :clone, params: {
              course_id: @largeCourse.id,
              id: @ts2.id,
              teamset: @largeTs.id
            }
    end
    @ts2.reload
    assert_equal 5, @ts2.teams.count
  end

  test "shouldn't update team with same start and end date" do 
    sign_in @fred
    assert_no_difference('Team.count') do
      patch :update, params: {
              course_id: @team.course,
              id: @team.teamset_id,
              single: { start_date: Date.current, end_date: Date.current },
              users: [ @mark.id, @jane.id, @greg.id ] }
    end
    assert_response :redirect
  end

  test "shouldn't update team with end date before start date" do 
    sign_in @fred
    assert_no_difference('Team.count') do
      patch :update, params: {
              course_id: @team.course,
              id: @team.teamset_id,
              single: { start_date: Date.current, end_date: Date.yesterday },
              users: [ @mark.id, @jane.id, @greg.id ] }
    end
    assert_response :redirect
  end

  test "should be able to bulk enter teams with valid dates" do
    sign_in @fred
    assert_difference('Team.count', 2) do
      patch :bulk_enter, params: {
        course_id: @team.course,
        id: @team.teamset_id,
        bulk: {
          teams: [
            [@mark.username, @jane.username], [@greg.username]
          ].map(&:to_csv).join,

      
          start_date: Date.current,
          end_date: Date.tomorrow        
        }
      }
    end
    assert_response :redirect
  end

  test "shouldn't be able to bulk enter team with end date on the start date" do
    sign_in @fred
    assert_no_difference('Team.count') do
      patch :bulk_enter, params: {
        course_id: @team.course,
        id: @team.teamset_id,
        bulk: {
          teams: [
            [@mark.username, @jane.username], [@greg.username]
          ].map(&:to_csv).join,

      
          start_date: Date.current,
          end_date: Date.current        
        }
      }
    end
    assert_response :redirect
    assert_equal "Cannot create teams with the end date on or before the start date.", flash[:alert]
  end

  test "shouldn't be able to bulk enter team with end date before the start date" do
    sign_in @fred
    assert_no_difference('Team.count') do
      patch :bulk_enter, params: {
        course_id: @team.course,
        id: @team.teamset_id,
        bulk: {
          teams: [
            [@mark.username, @jane.username], [@greg.username]
          ].map(&:to_csv).join,

      
          start_date: Date.current,
          end_date: Date.yesterday        
        }
      }
    end
    assert_response :redirect
    assert_equal "Cannot create teams with the end date on or before the start date.", flash[:alert]
  end

end
