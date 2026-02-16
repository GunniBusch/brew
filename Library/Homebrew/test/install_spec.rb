# typed: strict
# frozen_string_literal: true

require "install"

RSpec.describe Homebrew::Install do
  describe ".fetch_formulae" do
    it "yields installers one formula at a time" do
      queue = instance_double(Homebrew::DownloadQueue)
      fi_one = instance_double(FormulaInstaller)
      fi_two = instance_double(FormulaInstaller)
      formula_one = instance_double(Formula, name: "one")
      formula_two = instance_double(Formula, name: "two")

      allow(Homebrew::EnvConfig).to receive(:download_concurrency).and_return(2)
      allow(Homebrew::DownloadQueue).to receive(:new).with(pour: true).and_return(queue)
      expect(queue).to receive(:fetch).exactly(6).times
      expect(queue).to receive(:shutdown).once
      allow(described_class).to receive(:oh1)

      call_order = []
      yielded = []

      allow(fi_one).to receive(:formula).and_return(formula_one)
      allow(fi_one).to receive(:download_queue=).with(queue) { call_order << :assign_one }
      allow(fi_one).to receive(:prelude_fetch) { call_order << :one_prelude_fetch }
      allow(fi_one).to receive(:prelude) { call_order << :one_prelude }
      allow(fi_one).to receive(:fetch) { call_order << :one_fetch }

      allow(fi_two).to receive(:formula).and_return(formula_two)
      allow(fi_two).to receive(:download_queue=).with(queue) { call_order << :assign_two }
      allow(fi_two).to receive(:prelude_fetch) { call_order << :two_prelude_fetch }
      allow(fi_two).to receive(:prelude) { call_order << :two_prelude }
      allow(fi_two).to receive(:fetch) { call_order << :two_fetch }

      described_class.fetch_formulae([fi_one, fi_two]) do |fi|
        yielded << fi
        call_order << :"yield_#{fi.formula.name}"
      end

      expect(yielded).to eq([fi_one, fi_two])
      expect(call_order.index(:yield_one)).to be < call_order.index(:two_prelude_fetch)
    end
  end

  describe ".install_formulae" do
    it "installs each formula as soon as fetch_formulae yields it" do
      fi_one = instance_double(FormulaInstaller)
      fi_two = instance_double(FormulaInstaller)
      formula_one = instance_double(Formula, name: "one", linked?: false, outdated?: false, head?: false)
      formula_two = instance_double(Formula, name: "two", linked?: false, outdated?: false, head?: false)

      allow(fi_one).to receive(:formula).and_return(formula_one)
      allow(fi_two).to receive(:formula).and_return(formula_two)
      allow(Homebrew::EnvConfig).to receive(:no_install_upgrade?).and_return(false)

      expect(described_class).to receive(:fetch_formulae).with([fi_one, fi_two])
                                                         .and_yield(fi_one)
                                                         .and_yield(fi_two)
      expect(described_class).to receive(:install_formula).with(fi_one, upgrade: false).ordered
      expect(Cleanup).to receive(:install_formula_clean!).with(formula_one).ordered
      expect(described_class).to receive(:install_formula).with(fi_two, upgrade: false).ordered
      expect(Cleanup).to receive(:install_formula_clean!).with(formula_two).ordered

      described_class.install_formulae([fi_one, fi_two])
    end
  end
end
