# frozen_string_literal: true

RSpec.describe "Plain Ruby, without Rails" do # rubocop:disable RSpec/DescribeClass
  it "delivers through the mail gem without loading Rails or ActiveSupport" do
    output, status = Subprocess.run_ruby("scripts/plain_ruby.rb")

    expect(status).to be_success, output
    expect(output).to include("plain ruby ok")
  end
end
