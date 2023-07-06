# if this example path is changed from examples/button.rb update in docs too

Shoes.app do
  @push = button "Push me"
  @note = para "Nothing pushed so far"
  @push.click {
    @note.replace(
      "Aha! Click! ",
      link("Go back") { @note.replace "Nothing pushed so far" }
    )
  }
end
