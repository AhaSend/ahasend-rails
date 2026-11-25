# frozen_string_literal: true

require "open3"
require "rbconfig"

# Runs a Ruby script from spec/ in a fresh process with the gem's lib on the
# load path (and the current bundle, inherited through RUBYOPT/BUNDLE_GEMFILE).
module Subprocess
  LIB = File.expand_path("../../lib", __dir__)

  def self.run_ruby(script)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", LIB, File.expand_path(script, File.join(__dir__, "..")))
    [output, status]
  end

  # The host app's scenario results, computed once per test run.
  def self.host_app_results
    @host_app_results ||= begin
      output, status = run_ruby("scripts/host_app.rb")
      line = output.lines.find { |l| l.start_with?("AHASEND_RESULTS:") }
      raise "host app failed (exit #{status.exitstatus}):\n#{output}" unless status.success? && line

      JSON.parse(line.delete_prefix("AHASEND_RESULTS:"))
    end
  end
end
