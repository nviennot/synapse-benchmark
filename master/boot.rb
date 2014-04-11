require 'bundler'
Bundler.require

require 'abricot/master'

@abricot = Abricot::Master.new(:redis => 'redis://master/2')
def run(script, desc, options={})
  @abricot.exec(script, options.merge(:name => desc))
end

def kill_all
  @abricot.kill_all
end

def ruby_exec(cmd)
  "unset BUNDLE_GEMFILE && unset RVM_ENV && unset BUNDLE_BIN_PATH && unset RUBYOPT && exec rvm ruby-2.1.1 do bundle exec #{cmd}"
end
