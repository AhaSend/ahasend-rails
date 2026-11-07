# frozen_string_literal: true

require_relative "lib/ahasend/version"

Gem::Specification.new do |spec|
  spec.name = "ahasend-rails"
  spec.version = AhaSend::VERSION
  spec.authors = ["AhaSend", "Aamir Yaqoob"]
  spec.email = ["support@ahasend.com"]

  spec.summary = "ActionMailer delivery method for the AhaSend email API (v2)"
  spec.description = "Send Rails ActionMailer and Ruby Mail messages through the AhaSend HTTP API " \
                     "instead of SMTP, with support for attachments, tags, tracking, scheduling, " \
                     "sandbox mode and idempotent retries."
  spec.homepage = "https://github.com/AhaSend/ahasend-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "https://ahasend.com/docs"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ spec/ gemfiles/ .git .github Gemfile .rspec .rubocop.yml .gitattributes])
    end
  end
  spec.require_paths = ["lib"]

  # `mail` is the only hard dependency: it is what ActionMailer hands us and
  # what plain-Ruby users build messages with. ActionMailer itself is optional
  # so the delivery method works outside Rails too.
  spec.add_dependency "mail", ">= 2.7", "< 3"
end
