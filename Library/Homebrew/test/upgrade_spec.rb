# typed: strict
# frozen_string_literal: true

require "upgrade"

RSpec.describe Homebrew::Upgrade do
  describe ".upgrade_formulae" do
    it "upgrades each formula as it is yielded by fetch_formulae" do
      fi_one = instance_double(FormulaInstaller)
      fi_two = instance_double(FormulaInstaller)
      formula_one = instance_double(Formula)
      formula_two = instance_double(Formula)

      allow(fi_one).to receive(:formula).and_return(formula_one)
      allow(fi_two).to receive(:formula).and_return(formula_two)

      expect(Install).to receive(:fetch_formulae).with([fi_one, fi_two])
                                                 .and_yield(fi_one)
                                                 .and_yield(fi_two)
      expect(described_class).to receive(:upgrade_formula).with(fi_one, dry_run: false, verbose: false).ordered
      expect(Cleanup).to receive(:install_formula_clean!).with(formula_one, dry_run: false).ordered
      expect(described_class).to receive(:upgrade_formula).with(fi_two, dry_run: false, verbose: false).ordered
      expect(Cleanup).to receive(:install_formula_clean!).with(formula_two, dry_run: false).ordered

      described_class.upgrade_formulae([fi_one, fi_two])
    end
  end
end
