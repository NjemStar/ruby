require_relative '../../spec_helper'
require_relative 'fixtures/classes'

describe "IO#fsync" do
  before :each do
    @name = tmp("io_fsync.txt")
    ScratchPad.clear
  end

  after :each do
    rm_r @name
  end

  it "raises an IOError on closed stream" do
    -> { IOSpecs.closed_io.fsync }.should raise_error(IOError)
  end

  it "writes the buffered data to permanent storage" do
    File.open(@name, "w") do |f|
      f.write "one hit wonder"
      f.fsync.should == 0
    end
  end
end
