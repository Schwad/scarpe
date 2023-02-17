# frozen_string_literal: true

require "test_helper"

class TestPara < Minitest::Test
  def test_renders_paragraph
    para = Scarpe::Para.new("Hello World")
    html_id = para.html_id

    assert_html para.to_html, :p, id: html_id, style: "font-size:12px" do
      "Hello World"
    end
  end

  def test_renders_paragraph_with_collection_of_arguments
    para = Scarpe::Para.new(
      "Testing test test. ",
      "Breadsticks. ",
      "Breadsticks. ",
      "Breadsticks. ",
      "Very good.",
    )

    assert_html para.to_html, :p, id: para.html_id, style: "font-size:12px" do
      "Testing test test. Breadsticks. Breadsticks. Breadsticks. Very good."
    end
  end

  def test_renders_a_magenta_paragraph
    para = Scarpe::Para.new("Hello World", stroke: :magenta)

    assert_html para.to_html, :p, id: para.html_id, style: "color:magenta;font-size:12px" do
      "Hello World"
    end
  end

  def test_renders_a_blue_paragraph_with_class_attribute
    para = Scarpe::Para.new("Hello World", class: :sea, stroke: :blue)

    assert_html para.to_html, :p, class: "sea", id: para.html_id, style: "color:blue;font-size:12px" do
      "Hello World"
    end
  end

  def test_renders_paragraph_with_size_number
    para = Scarpe::Para.new("Oh, to fling and be flung", size: 48)

    assert_html para.to_html, :p, id: para.html_id, style: "font-size:48px" do
      "Oh, to fling and be flung"
    end
  end

  def test_renders_paragraph_with_size_symbol
    para = Scarpe::Para.new("Oh, to fling and be flung", size: :banner)

    assert_html para.to_html, :p, id: para.html_id, style: "font-size:48px" do
      "Oh, to fling and be flung"
    end
  end

  def test_replace_children
    stub_document_root

    para = Scarpe::Para.new("Oh, to fling and be flung", size: :banner)

    para.replace("Oh, to be flung and to fling")

    assert_html para.to_html, :p, id: para.html_id, style: "font-size:48px" do
      "Oh, to be flung and to fling"
    end
  end

  def test_children_can_be_text_widgets
    strong = Scarpe::Strong.new("I am strong")
    para = Scarpe::Para.new(strong)

    assert_html para.to_html, :p, id: para.html_id, style: "font-size:12px" do
      strong.to_html
    end
  end

  def test_can_replace_widgets_with_other_widgets
    stub_document_root

    strong = Scarpe::Strong.new("I am strong")
    em = Scarpe::Strong.new("I am em")
    para = Scarpe::Para.new(strong)

    para.replace(em)

    assert_html para.to_html, :p, id: para.html_id, style: "font-size:12px" do
      em.to_html
    end
  end

  private

  def stub_document_root
    doc_root = Minitest::Mock.new
    elt_wrangler = Minitest::Mock.new
    web_wrangler = Minitest::Mock.new
    doc_root.expect :get_element_wrangler, elt_wrangler, [String]
    doc_root.expect :request_full_redraw!, nil
    elt_wrangler.expect :inner_html=, nil, [String]
    web_wrangler.expect :dom_change, nil, [String]
    web_wrangler.expect :dom_promise_redraw, nil

    Scarpe::Widget.document_root = doc_root
    Scarpe::Widget.web_wrangler = web_wrangler
  end
end
