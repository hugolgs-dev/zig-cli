/// The first part of this file defines the core data structures of the CLI.
/// Types are required to represent commands & options.

// imports of standard Zig libraries
const std = @import("std"); // standard lib
const builtin = @import("builtin"); // compiler-specific info

// constants (names are self-explanatory ig)
pub const MAX_COMMANDS: u8 = 10; // CLI supports 10 commands
pub const MAX_OPTIONS: u8 = 20; // CLI supports 20 options
/// u8: type, unsigned 8-bit integer (holds value from 0 to 255).
/// goal of type: to give precise control over size of number
/// pub const => public constant --> usable outside of the file/module
const Byte = u8;
const Slice = []const Byte;
const Slices = []const Slice;

// Structure to represent the type of command.
pub const command = struct {
    name: Slice, // Name of the command
    func: fnType, // Function to execute the command
    req: Slices = &.{}, // Required options
    opt: Slices = &.{}, // Optional options
    const fnType = *const fn ([]const option) bool;
};

// Structure to represent the type of option.
pub const option = struct {
    name: Slice, // Name of the option
    func: ?fnType = null, // Function to execute the option
    short: Byte, // Short form, e.g., -n|-N
    long: Slice, // Long form, e.g., --name
    value: Slice = "", // Value of the option
    const fnType = *const fn (Slice) bool;
};

// Possible errors during CLI execution
// names are self-explanatory
pub const Error = error{
    NoArgsProvided,
    UnknownCommand,
    UnknownOption,
    MissingRequiredOption,
    UnexpectedArgument,
    CommandExecutionFailed,
    TooManyCommands,
    TooManyOptions,
};

// Additional notes:
// Zig does not use generic names for integers like "int",
// The size of said integer must be specified using types: u8, u16, u32, etc.

//////////////////////////////////////////////////////////////////////////////

// The second part of this file implements the parser
// The goal of the parser is to parse command-line arguments into commands,
// and then execute these commands.

// Start of the CLI application

/// Entry point of the CLI => function start() that... starts the CLI
/// Parameters of the function:
/// - commands: []const command => type is a slice of []const command => read-only list of command structures
/// - options: []const option => type is a slice of []const option => read-only list of option structures
/// - debug: bool => boolean flag. If true, debug messages are enabled
/// - !void => no value on success, but can fail with an error (denoted by the !)
pub fn start(commands: []const command, options: []const option, debug: bool) !void {
    // return an error if too many commands and/or options
    if (commands.len > MAX_COMMANDS) {
        return error.TooManyCommands;
    }
    if (options.len > MAX_OPTIONS) {
        return error.TooManyOptions;
    }

    // Create a general-purpose allocator for managing memory during execution
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Retrieve the command-line arguments in a cross-platform manner
    const args = try std.process.argsAlloc(allocator);
    // args[0] => name of the program
    // args[1], args[2], etc => user input
    defer std.process.argsFree(allocator, args);
    // defer: ensure memory is free when done

    // function passes control to the real logic, the function startWithArgs
    try startWithArgs(commands, options, args, debug);
}

/// Starts the CLI application with provided arguments.
/// This function does the actual parsing and command execution
/// commands: array of available commands;
/// options: array of available options;
/// args: number of command-line arguments
/// debug: see last function
/// !void: see last function
pub fn startWithArgs(commands: []const command, options: []const option, args: anytype, debug: bool) !void {
    // check for missing commands (arg[0] is program name, so if no arg[1] => not command)
    if (args.len < 2) {
        if (debug) std.debug.print("No command provided by user!\n", .{});
        return Error.NoArgsProvided;
    }

    // Extract the name of the command (the second argument after the program name)
    const command_name = args[1]; // first argument: name of the command
    var detected_command: ?command = null; // initially null

    // Search through the list of available commands to find a match
    for (commands) |cmd| {
        // std.mem.eql to compare strings:
        // cmd.name: name of each element in the commands array
        if (std.mem.eql(u8, cmd.name, command_name)) {
            detected_command = cmd;
            break;
        }
    }

    // If no matching command is found, return an error
    if (detected_command == null) {
        if (debug) std.debug.print("Unknown command: {s}\n", .{command_name});
        return Error.UnknownCommand;
    }

    // Retrieve the matched command from the optional variable
    // we unwrap the optional (?) and log/store the matched command into cmd
    const cmd = detected_command.?;

    // print selected command if debugging is on
    if (debug) std.debug.print("Detected command: {s}\n", .{cmd.name});

    // Allocate memory for detected options based on remaining arguments
    // this part sets up the parser for options
    var detected_options: [MAX_OPTIONS]option = undefined; // we collect matched options here
    var detected_len: usize = 0; // detected_len tracks how many options we find
    var i: usize = 2; // sets parsing after args[2], so after program name and command

    // Parsing options to capture their values
    while (i < args.len) {
        const arg = args[i];

        // if the argument starts with an - => treat it as an option. otherwise, it's an invalid argument
        if (std.mem.startsWith(u8, arg, "-")) {
            // we get the name of the option
            ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
            const option_name = if (std.mem.startsWith(u8, arg[1..], "-")) arg[2..] else arg[1..];
            var matched_option: ?option = null;

            for (options) |opt| {
                if (std.mem.eql(u8, option_name, opt.long) or (option_name.len == 1 and option_name[0] == opt.short)) {
                    matched_option = opt;
                    break;
                }
            }

            if (matched_option == null) {
                if (debug) std.debug.print("Unknown option: {s}\n", .{arg});
                return Error.UnknownOption;
            }

            var opt = matched_option.?;

            // Detect the value for the option
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                opt.value = args[i + 1];
                i += 1;
            } else {
                opt.value = "";
            }

            if (detected_len >= MAX_OPTIONS) {
                return error.TooManyOptions;
            }

            detected_options[detected_len] = opt;
            detected_len += 1;
        } else {
            if (debug) std.debug.print("Unexpected argument: {s}\n", .{arg});
            return Error.UnexpectedArgument;
        }

        i += 1;
    }

    // Slice the detected options to the actual number of detected options
    const used_options = detected_options[0..detected_len];

    // Ensure all required options for the detected command are provided
    for (cmd.req) |req_option| {
        var found = false;

        for (used_options) |opt| {
            if (std.mem.eql(u8, req_option, opt.name)) {
                found = true;
                break;
            }
        }

        if (!found) {
            if (debug) std.debug.print("Missing required option: {s}\n", .{req_option});
            return Error.MissingRequiredOption;
        }
    }

    // Execute the command's associated function with the detected options
    if (!cmd.func(used_options)) {
        return Error.CommandExecutionFailed;
    } else {
        // Execute option functions
        for (used_options) |opt| {
            if (opt.func == null) continue;

            const result = opt.func.?(opt.value);

            if (!result) {
                if (debug) std.debug.print("Option function execution failed: {s}\n", .{opt.name});
                return Error.CommandExecutionFailed;
            }
        }
    }

    // If execution reaches this point, the command was executed successfully
    if (debug) std.debug.print("Command executed successfully: {s}\n", .{cmd.name});
}
