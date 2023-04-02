## IN DEVELOPMENT

Glimmer LibUI is a fully functioning way to build desktop applications in Ruby.

One possible way to make this work would be a parser-compiler setup to essentially _transform_ shoes app text into GlimmerLibUI text. Which should be abstract enough that we wouldn't have to go more bare metal and use the ruby dependency LibUI.

Hello world example:

```ruby
# parser/compiler example:

Shoes.app do
  para "Hello World"
end

# becomes

include Glimmer

window {
  area {
    text {
      string "Hello World"
    }
  }
}.show
```

# GLibUI Finished Examples

* /examples/hello_world.rb
* /examples/title_and_resize.rb
* /examples/stack/raw_stack.rb
* /examples/raw_flow.rb
