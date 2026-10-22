# Parse the front matter of every document and the header of every Pascal file as YAML.
#
#   ruby tools/check/yaml_headers.rb
#
# The script runs from the root of the repository. It reports a document without the
# front matter, a Pascal file whose header lacks the "{**" and "---" lines in this order,
# a blank line before the closing brace, and a header that is not a YAML map. The usual
# fault is a ": " inside a plain scalar. The exit code is 1 when a fault is found.
require 'yaml'
bad = 0
Dir['doc/**/*.md'].sort.each do |f|
  t = File.read(f)
  m = t.match(/\A---\n(.*?)\n---\n/m)
  (puts "NOFM #{f}"; bad += 1; next) unless m
  begin; y = YAML.safe_load(m[1]); raise 'not a map' unless y.is_a?(Hash)
  rescue => e; puts "YAML #{f}: #{e.message[0,120]}"; bad += 1; end
end
(Dir['src/*.pas'] + Dir['test/*.pas'] + Dir['examples/*.pas']).sort.each do |f|
  t = File.read(f)
  m = t.match(/\A\{\*\*\n---\n(.*?)\n---\n(\n?)\}\n/m)
  (puts "HDR #{f}"; bad += 1; next) unless m
  puts "BLANKBEFORE} #{f}" unless m[2].empty?
  begin; y = YAML.safe_load(m[1]); raise 'not a map' unless y.is_a?(Hash)
  rescue => e; puts "YAML #{f}: #{e.message[0,120]}"; bad += 1; end
end
puts "bad=#{bad}"
exit(bad.zero? ? 0 : 1)
