task :default => :test

task :parser do
  sh "kpeg -f -s lib/hummus.kpeg"
end

task :formatter do
  sh "kpeg -f -s lib/formatter.kpeg"
end

task :clean do
  sh "find . -name '*.rbc' -delete; find . -name '*.ayc' -delete"
end

task :install do
  sh "rm *.gem; rbx -S gem uninstall hummus; rbx -S gem build hummus.gemspec; rbx -S gem install hummus-*.gem --no-ri --no-rdoc"
end
