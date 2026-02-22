# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "test_runner_formula"
require "github_runner_matrix"
require "sharded_runner_matrix"

module Homebrew
  module DevCmd
    class DetermineTestRunners < AbstractCommand
      class ParsedIntegerShardOption < T::Struct
        const :global_value, Integer
        const :runner_overrides, T::Hash[String, Integer]
      end

      class ParsedFloatShardOption < T::Struct
        const :global_value, Float
        const :runner_overrides, T::Hash[String, Float]
      end

      cmd_args do
        usage_banner <<~EOS
          `determine-test-runners` {<testing-formulae> [<deleted-formulae>]|--all-supported}

          Determines the runners used to test formulae or their dependents. For internal use in Homebrew taps.
        EOS
        switch "--all-supported",
               description: "Instead of selecting runners based on the chosen formula, return all supported runners."
        switch "--eval-all",
               description: "Evaluate all available formulae, whether installed or not, to determine testing " \
                            "dependents.",
               env:         :eval_all
        switch "--dependents",
               description: "Determine runners for testing dependents. " \
                            "Requires `--eval-all` or `HOMEBREW_EVAL_ALL=1` to be set.",
               depends_on:  "--eval-all"
        flag "--dependent-shard-max-runners=",
             description: "Maximum dependent shards when using `--dependents`. Accepts either a single value " \
                          "or comma-separated per-runner overrides (e.g. " \
                          "`linux-x86_64=4,macos-arm64=2`).",
             depends_on:  "--dependents"
        flag "--dependent-shard-min-dependents-per-runner=",
             description: "Minimum dependent formulae per shard when using `--dependents`. Accepts either a " \
                          "single value or comma-separated per-runner overrides (e.g. " \
                          "`linux-x86_64=200,macos-arm64=100`).",
             depends_on:  "--dependents"
        flag "--dependent-shard-runner-load-factor=",
             description: "Minimum shard load ratio (0,1] when expanding dependents. Accepts either a single " \
                          "value or comma-separated per-runner overrides (e.g. " \
                          "`linux-x86_64=0.8,macos-arm64=0.6`).",
             depends_on:  "--dependents"

        named_args max: 2

        conflicts "--all-supported", "--dependents"

        hide_from_man_page!
      end

      sig { override.void }
      def run
        if args.no_named? && !args.all_supported?
          raise Homebrew::CLI::MinNamedArgumentsError, 1
        elsif args.all_supported? && !args.no_named?
          raise UsageError, "`--all-supported` is mutually exclusive to other arguments."
        end

        shard_max_runners = dependent_shard_max_runners_value
        shard_min_items_per_runner = dependent_shard_min_dependents_per_runner_value
        shard_runner_load_factor = dependent_shard_runner_load_factor_value

        testing_formulae = args.named.first&.split(",").to_a.map do |name|
          TestRunnerFormula.new(Formulary.factory(name), eval_all: args.eval_all?)
        end.freeze
        deleted_formulae = args.named.second&.split(",").to_a.freeze

        runner_matrix_class = if args.dependents?
          ShardedRunnerMatrix
        else
          GitHubRunnerMatrix
        end
        runner_matrix_args = {
          all_supported:    args.all_supported?,
          dependent_matrix: args.dependents?,
        }
        if args.dependents?
          runner_matrix_args[:shard_max_runners] = shard_max_runners.global_value
          runner_matrix_args[:shard_max_runners_by_runner_type] = shard_max_runners.runner_overrides
          runner_matrix_args[:shard_min_items_per_runner] = shard_min_items_per_runner.global_value
          runner_matrix_args[:shard_min_items_per_runner_by_runner_type] = shard_min_items_per_runner.runner_overrides
          runner_matrix_args[:shard_runner_load_factor] = shard_runner_load_factor.global_value
          runner_matrix_args[:shard_runner_load_factor_by_runner_type] = shard_runner_load_factor.runner_overrides
          runner_matrix_args[:shard_count_key] = ShardedRunnerMatrix::ShardCountKey::DependentShardCount
          runner_matrix_args[:shard_index_key] = ShardedRunnerMatrix::ShardIndexKey::DependentShardIndex
        end
        runner_matrix = runner_matrix_class.new(testing_formulae, deleted_formulae, **runner_matrix_args)
        runners = runner_matrix.active_runner_specs_hash

        ohai "Runners", JSON.pretty_generate(runners)

        # gracefully handle non-GitHub Actions environments
        github_output = if ENV.key?("GITHUB_ACTIONS")
          ENV.fetch("GITHUB_OUTPUT")
        else
          ENV.fetch("GITHUB_OUTPUT", nil)
        end
        return unless github_output

        File.open(github_output, "a") do |f|
          f.puts("runners=#{runners.to_json}")
          f.puts("runners_present=#{runners.present?}")
        end
      end

      private

      sig { returns(ParsedIntegerShardOption) }
      def dependent_shard_max_runners_value
        parse_positive_integer_option(
          args.dependent_shard_max_runners,
          "--dependent-shard-max-runners",
          default_value: ShardedRunnerMatrix::DEFAULT_SHARD_MAX_RUNNERS,
        )
      end

      sig { returns(ParsedIntegerShardOption) }
      def dependent_shard_min_dependents_per_runner_value
        parse_positive_integer_option(
          args.dependent_shard_min_dependents_per_runner,
          "--dependent-shard-min-dependents-per-runner",
          default_value: ShardedRunnerMatrix::DEFAULT_SHARD_MIN_ITEMS_PER_RUNNER,
        )
      end

      sig { returns(ParsedFloatShardOption) }
      def dependent_shard_runner_load_factor_value
        parse_load_factor_option(
          args.dependent_shard_runner_load_factor,
          "--dependent-shard-runner-load-factor",
          default_value: ShardedRunnerMatrix::DEFAULT_SHARD_RUNNER_LOAD_FACTOR,
        )
      end

      sig {
        params(
          raw_value:     T.nilable(String),
          flag_name:     String,
          default_value: Integer,
        ).returns(ParsedIntegerShardOption)
      }
      def parse_positive_integer_option(raw_value, flag_name, default_value:)
        return ParsedIntegerShardOption.new(global_value: default_value, runner_overrides: {}) if raw_value.blank?

        global_value = T.let(default_value, Integer)
        has_global_override = T.let(false, T::Boolean)
        runner_overrides = T.let({}, T::Hash[String, Integer])

        parse_option_entries(raw_value, flag_name).each do |entry|
          if entry.include?("=")
            runner_type_key, raw_entry_value = parse_runner_override_entry(entry, flag_name)
            parsed_value = T.let(Integer(raw_entry_value, exception: false), T.nilable(Integer))
            if parsed_value.nil? || parsed_value < 1
              raise UsageError, "`#{flag_name}` values must be integers greater than or equal to 1."
            end

            runner_overrides[runner_type_key] = parsed_value
            next
          end

          raise UsageError, "`#{flag_name}` can only include one global value." if has_global_override

          parsed_value = T.let(Integer(entry, exception: false), T.nilable(Integer))
          if parsed_value.nil? || parsed_value < 1
            raise UsageError, "`#{flag_name}` must be an integer greater than or equal to 1."
          end

          global_value = parsed_value
          has_global_override = true
        end

        ParsedIntegerShardOption.new(global_value:, runner_overrides:)
      end

      sig {
        params(
          raw_value:     T.nilable(String),
          flag_name:     String,
          default_value: Float,
        ).returns(ParsedFloatShardOption)
      }
      def parse_load_factor_option(raw_value, flag_name, default_value:)
        return ParsedFloatShardOption.new(global_value: default_value, runner_overrides: {}) if raw_value.blank?

        global_value = T.let(default_value, Float)
        has_global_override = T.let(false, T::Boolean)
        runner_overrides = T.let({}, T::Hash[String, Float])

        parse_option_entries(raw_value, flag_name).each do |entry|
          if entry.include?("=")
            runner_type_key, raw_entry_value = parse_runner_override_entry(entry, flag_name)
            parsed_value = T.let(Float(raw_entry_value, exception: false), T.nilable(Float))
            if parsed_value.nil? || !ShardedRunnerMatrix.valid_shard_runner_load_factor?(parsed_value)
              raise UsageError, "`#{flag_name}` values must be numbers greater than 0 and less than or equal to 1."
            end

            runner_overrides[runner_type_key] = parsed_value
            next
          end

          raise UsageError, "`#{flag_name}` can only include one global value." if has_global_override

          parsed_value = T.let(Float(entry, exception: false), T.nilable(Float))
          if parsed_value.nil? || !ShardedRunnerMatrix.valid_shard_runner_load_factor?(parsed_value)
            raise UsageError, "`#{flag_name}` must be a number greater than 0 and less than or equal to 1."
          end

          global_value = parsed_value
          has_global_override = true
        end

        ParsedFloatShardOption.new(global_value:, runner_overrides:)
      end

      sig { params(raw_value: String, flag_name: String).returns(T::Array[String]) }
      def parse_option_entries(raw_value, flag_name)
        entries = raw_value.split(",").map(&:strip).reject(&:empty?)
        raise UsageError, "`#{flag_name}` cannot be empty." if entries.empty?

        entries
      end

      sig { params(entry: String, flag_name: String).returns([String, String]) }
      def parse_runner_override_entry(entry, flag_name)
        runner_type_key, raw_entry_value = entry.split("=", 2)
        runner_type_key = runner_type_key.to_s.strip
        raw_entry_value = raw_entry_value.to_s.strip

        validate_runner_type_key!(runner_type_key, flag_name)
        if raw_entry_value.empty?
          raise UsageError, "`#{flag_name}` runner overrides must include a value (e.g. `linux-x86_64=2`)."
        end

        [runner_type_key, raw_entry_value]
      end

      sig { params(runner_type_key: String, flag_name: String).void }
      def validate_runner_type_key!(runner_type_key, flag_name)
        return if ShardedRunnerMatrix.valid_runner_type_key?(runner_type_key)

        valid_keys = ShardedRunnerMatrix.runner_type_keys.join(", ")
        raise UsageError,
              "`#{flag_name}` has unknown runner type `#{runner_type_key}`. Valid runner types: #{valid_keys}."
      end
    end
  end
end
