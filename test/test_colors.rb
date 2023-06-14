# frozen_string_literal: true

require "test_helper"

class TestColors < ScarpeTest
  class Dummy
    include Scarpe::Colors
  end

  def test_default_colors_are_accessible_via_methods
    assert_equal [0, 0, 0, 255], Dummy.new.black
    assert_equal [255, 255, 255, 255], Dummy.new.white
  end

  def test_default_colors_can_accept_alpha
    assert_equal [0, 0, 0, 0.5], Dummy.new.black(0.5)
  end

  def test_gray_accepts_single_value_for_darkness
    assert_equal [0, 0, 0, 255], Dummy.new.gray(0)
    assert_equal [255, 255, 255, 255], Dummy.new.gray(255)
  end

  def test_gray_accepts_darkness_and_alpha
    assert_equal [0, 0, 0, 128], Dummy.new.gray(0, 128)
  end

  def test_gray_defaults_to_50_percent_darkness
    assert_equal [128, 128, 128, 255], Dummy.new.gray
  end

  def test_rgb_accepts_three_values
    assert_equal [255, 0, 0, 255], Dummy.new.rgb(255, 0, 0)
  end

  def test_rgb_accepts_alpha
    assert_equal [255, 0, 0, 128], Dummy.new.rgb(255, 0, 0, 128)
  end
end
