Shoes.app do
  def collapsed
    @para = para(
      "'Scarpe' means shoes in Italian. 'Scarpe' also means Shoes in...",
      link("(show more)") { @para.destroy; @para = expanded }
    )
  end

  def expanded
    @para = para(
      "'Scarpe' means shoes in Italian. 'Scarpe' also means Shoes in modern Ruby and webview!</br>",
      "Scarpe isn't feature complete with any version of Shoes (yet?). We're initially targeting Shoes Classic. ",
      link("Learn more", click: -> { navigate_to("http://github.com/schwad/scarpe") }), # Update this line
      " ",
      link("(show less)") { @para.destroy; @para = collapsed }
    )
  end

  @para = collapsed
end
