# frozen_string_literal: false

puts "== Regenerating HTML fixtures =="

require 'fileutils'

# Get top-level Ruby examples
file_paths = Dir["examples/*.rb"]

# Get each filename, or one if supplied as argument
file_names = if ENV['SELECTED_FILE']
  [ENV['SELECTED_FILE']]
else
  file_paths.map do |file|
    File.basename(file) # Exclude the file extension
  end
end

collection_of_html = []
file_names.each do |file_name|
  # Read the entire file
  content = File.read(File.join(File.expand_path("../examples", __dir__),"#{file_name}"))
  # Skip this file if it contains the magic comment
  next if content.include?("# html_ci: false")

  output = ""
  pid = nil
  command = "bundle exec ./exe/scarpe examples/#{file_name} --dev --debug"

  IO.popen(command) do |io|
    pid = io.pid # captures the pid of the child process
    io.each_line do |line|
      output << line
      if line.include?(":heartbeat")
        Process.kill("SIGKILL", pid)
        break
      end
    end
  end

  # EXAMPLE_OF_WHAT_OUTPUT_LOOKS_LIKE = <<~OUTPUT
  #    INFO  WebviewAPI : Method: set_title Args: ["Shoes!"] KWargs: {} Block: n Return: nil
  #    INFO  WebviewAPI : Method: set_size Args: [480, 420, 0] KWargs: {} Block: n Return: nil
  #    INFO  WebviewAPI : Method: navigate Args: ["data:text/html, %3Chtml%3E%0A++%3Chead+id%3D%27head-wvroot%27%3E%0A++++%3Cstyle+id%3D%27style-wvroot%27%3E%0A++++++%2F%2A%2A+Style+resets+%2A%2A%2F%0A++++++body+%7B%0A++++++++font-family%3A+arial%2C+Helvetica%2C+sans-serif%3B%0A++++++++margin%3A+0%3B%0A++++++++height%3A+100%25%3B%0A++++++++overflow%3A+hidden%3B%0A++++++%7D%0A++++++p+%7B%0A++++++++margin%3A+0%3B%0A++++++%7D%0A++++++%23wrapper-wvroot+%7B%0A++++++++height%3A+100%25%3B%0A++++++++width%3A+100%25%3B%0A++++++%7D%0A++++%3C%2Fstyle%3E%0A++%3C%2Fhead%3E%0A++%3Cbody+id%3D%27body-wvroot%27%3E%0A++++%3Cdiv+id%3D%27wrapper-wvroot%27%3E%3C%2Fdiv%3E%0A++%3C%2Fbody%3E%0A%3C%2Fhtml%3E%0A"] KWargs: {} Block: n Return: nil
  #    INFO  WebviewAPI : Method: eval Args: ["function patchConsole(fn) {\n  const original = console[fn];\n  console[fn] = function(...args) {\n    original(...args);\n    puts(...args);\n  }\n};\npatchConsole('log');\npatchConsole('info');\npatchConsole('error');\npatchConsole('warn');\n"] KWargs: {} Block: n Return: nil
  #   DEBUG  Webview::WebWrangler::DOMWrangler : Requesting DOM replacement...
  #   DEBUG  Webview::WebWrangler::DOMWrangler : Requesting redraw with 1 waiting changes and no waiting promise - need to schedule something!
  #   DEBUG  Webview::WebWrangler::DOMWrangler : Requesting redraw with 1 waiting changes - scheduling a new redraw for them!
  #    INFO  WebviewAPI : Method: eval Args: ["(function() {\n  var code_string = "document.getElementById('wrapper-wvroot').innerHTML = `<div id=\\"2\\" style=\\"display:flex;flex-direction:row;flex-wrap:wrap;align-content:flex-start;justify-content:flex-start;align-items:flex-start;width:100%;height:100%\\"><button id=\\"3\\" onclick=\\"scarpeHandler('3-click')\\" onmouseover=\\"scarpeHandler('3-hover')\\">Push me</button><div id=\\"root-fonts\\"></div><div id=\\"root-alerts\\"> </div></div>`; true";\n  try {\n    result = eval(code_string);\n    scarpeAsyncEvalResult("success", 0, result);\n  } catch(error) {\n    scarpeAsyncEvalResult("error", 0, error.message);\n  }\n})();\n"] KWargs: {} Block: n Return: nil
  #   DEBUG  Webview::WebWrangler : Scheduled JS: (0)
  #   (function() {
  #     var code_string = "document.getElementById('wrapper-wvroot').innerHTML = `<div id="2" style="display:flex;flex-direction:row;flex-wrap:wrap;align-content:flex-start;justify-content:flex-start;align-items:flex-start;width:100%;height:100%"><button id="3" onclick="scarpeHandler('3-click')" onmouseover="scarpeHandler('3-hover')">Push me</button><div id="root-fonts"></div><div id="root-alerts"> </div></div>`; true";
  #     try {
  #       result = eval(code_string);
  #       scarpeAsyncEvalResult("success", 0, result);
  #     } catch(error) {
  #       scarpeAsyncEvalResult("error", 0, error.message);
  #     }
  #   })();
  # OUTPUT

  require "htmlbeautifier"

  def match_output(logs)
    logs.match(/(?<=code_string = ").*(?=")/)[0].split("`")[1]
  end

  def format_html(html)
    html.gsub!(/\\/, "") # Remove all backslashes
    html
  end

  html = format_html(
    match_output(output),
  )
  # puts formatted_html
  pretty_html = HtmlBeautifier.beautify(html)

  collection_of_html << [file_name, pretty_html]

  # EXAMPLE_OF_WHAT_PRETTY_HTML_LOOKS_LIKE = <<~PRETTY_HTML
  # <div id="2" style="display:flex;flex-direction:row;flex-wrap:wrap;align-content:flex-start;justify-content:flex-start;align-items:flex-start;width:100%;height:100%"><button id="3" onclick="scarpeHandler('3-click')" onmouseover="scarpeHandler('3-hover')">Push me</button>
  #   <div id="root-fonts"></div>
  #   <div id="root-alerts"> </div>
  # </div>
  # PRETTY_HTML

  # Write to fixtures
  dir_path = "test/wv/html_fixtures"
  file_path = "#{dir_path}/#{file_name.split(".")[0]}.html"

  # Create the directory if it doesn't exist
  FileUtils.mkdir_p(dir_path)

  # Write the HTML to the file
  File.write(file_path, pretty_html)


  collection_of_html << [file_name, html]
end

# Show how it looks
# collection_of_html.map { |file_name, html| puts "File: #{file_name}\n\n HTML: #{html}" }
puts "HTML fixtures regenerated successfully!"
