# require 'shoes'

# Shoes.app title: "Cool Soundboard", width: 300, height: 250 do
#   background white
#   stack(margin: 12) do
#     title "Cool Soundboard", align: "center"

#     ["C", "D", "E", "F", "G", "A", "B", "+ C"].each do |note|
#       button note do
#         bloops_command = %{ruby -e 'require "bloops"; b = Bloops.new; sound = b.sound Bloops::SQUARE; b.tune sound, "#{note}"; b.play; sleep 1'}
#         system(bloops_command)
#       end
#     end
#   end
# end

# shoes_piano.rb
# require 'shoes'

# Shoes.app title: "Shoes Piano", width: 600, height: 400 do
#   background white

#   title "Shoes Piano", align: "center"

#   def play_sound(note)
#     bloops_command = %{ruby -e 'require "bloops"; b = Bloops.new; sound = b.sound Bloops::SINE; b.tune sound, "#{note}"; b.play; sleep 1'}
#     system(bloops_command)
#   end

#   notes = ["C", "D", "E", "F", "G", "A", "B", "+C"]

#   stack do
#     flow do
#       notes.each do |note|
#         stack(width: 50, height: 200) do
#           background white
#           border black

#           click do
#             play_sound(note)
#           end
#         end
#       end
#     end
#   end
# end
# # require 'shoes'
# require 'shoes'

# Shoes.app title: "Shoes Synth", width: 1140, height: 400 do
#   background linen

#   @waveform = "SQUARE"
#   @octave = 4

#   def play_sound(note)
#     bloops_command = %{ruby -e 'require "bloops"; b = Bloops.new; sound = b.sound Bloops::#{@waveform}; b.tune sound, "#{note}#{@octave}"; b.play; sleep 1'}
#     system(bloops_command)
#   end

#   white_notes = ["C", "D", "E", "F", "G", "A", "B", "+C"]
#   black_notes = ["C#", "D#", nil, "F#", "G#", "A#", nil]

#   stack do
#     flow do
#       list_box items: ["SQUARE", "SAWTOOTH", "SINE", "NOISE"],
#                choose: "SQUARE",
#                width: 120,
#                height: 30 do |list|
#         @waveform = list
#       end
#       list_box items: (0..8).to_a.map(&:to_s),
#                choose: 4,
#                width: 120,
#                height: 30 do |list|
#         @octave = list
#       end
#     end

#     flow do
#       7.times do |i|
#         stack margin_top: 10, width: 100, height: 200 do
#           background white
#           border black

#           click do
#             play_sound(white_notes[i])
#           end
#         end

#         if black_notes[i]
#           stack(margin_top: 2, width: 60, height: 120, margin_left: -30) do
#             background black
#             para strong(black_notes[i]), stroke: white, align: 'center'

#             click do
#               play_sound(black_notes[i])
#             end
#           end
#         end
#       end
#     end
#   end
# end
require 'shoes'
require 'bloops'

Shoes.app title: "Shoes Synth", width: 1140, height: 400 do
  background linen

  @waveform = Bloops::SQUARE
  @octave = "4"

  def play_sound(note)
    b = Bloops.new
    sound = b.sound @waveform
    b.tune sound, "#{note}#{@octave}"
    b.play
    sleep 1
  end

  white_notes = ["C", "D", "E", "F", "G", "A", "B", "+C"]
  black_notes = ["C#", "D#", nil, "F#", "G#", "A#", nil]

  stack do
    flow do
      list_box items: ["SQUARE", "SAWTOOTH", "SINE", "NOISE"],
               choose: "SQUARE",
               width: 120,
               height: 30 do |list|
        @waveform = Bloops.const_get(list.text)
      end

      list_box items: ("0".."8").to_a,
               choose: "4",
               width: 120,
               height: 30 do |list|
        @octave = list.text
      end
    end

    flow do
      7.times do |i|
        stack margin_top: 10, width: 100, height: 200 do
          background white
          border black

          click do
            play_sound(white_notes[i])
          end
        end

        if black_notes[i]
          stack(margin_top: 2, width: 60, height: 120, margin_left: -30) do
            background black
            para strong(black_notes[i]), stroke: white, align: 'center'

            click do
              play_sound(black_notes[i])
            end
          end
        end
      end
    end
  end
end
