# Contributing

## I want to contribute, but where do I begin ?

We track all our issues and feature requests on GitHub so you are at the right place!

If you think OpenStack_Taster should have a feature or you found a bug, you can report them here.

We could also do with some help with the user documentation.

If you want to wrangle with the code, all of the issues are labeled *Easy*, *Medium* or *Advanced* based on the work that we estimate it would take.

If you are just starting out programming/Ruby/OpenStack or new to this project, we encourage you to tackle the *Easy* ones first so that you also get a sense of how the code is organized and how it actually works.

*Medium* or *Advanced* level issues not only require you to understand the code but also understanding a bit of how OpenStack works and being able to test the change.

## What does X function do ? How does Z thing actually happen in your code? Where's your reference documentation ?

All our code is documentated using [YARD](http://yardoc.org/). To generate the documentation, clone the project, install the yard gem and run `yard` from the root of the project.

A `doc/` directory will be created with HTML documentation that is best viewed using open source browsers!

## How to add a new flag or a test suite?

If at some point in the future more features need to be added, please follow this guide.
`openstack_taster` was designed to make it easier for future developers to add features easily.

1. Flags  
If you want to add a flag to the tool, add an `opts.on` statement to the `OptionParser` block.
Here you can specify the short and long version of the flag as well as the description.
A block can be added to `opts.on` so that once it parses the flag, any code inside the block will run.

2. Test Suites  
If you want to add a test suite to `openstack_taster`, then there are only 3 things you need to do:
    1. Add a suite name and description to the `suites` hash. Do not use spaces.
    2. Add this line in `lib/openstack_taster.rb:taste`: `return_values.push taste_<suite_name>(<parameters>) if settings[:<suite_name>]`  
      `<suite_name>` is the name of your suite defined in the `suites` hash in `bin/openstack_taster`.
    3. Add your function to `lib/openstack_taster.rb`. The standard for suite function names is `taste_<suite_name>`.

## Ok, I have fixed something/added a new test suite/feature. How do I test it out?

As, the name of the project speaks for itself, you would require OpenStack to test. You could setup your own OpenStack in a VM by using something like [DevStack](https://docs.openstack.org/devstack/latest/). If that is too difficult, you can contact us and we *might* be able to provide you access to a cluster at OSL to test your changes.

## Should I submit a PR ? Is my PR ready to submit?

The answer is almost always **yes**!

What makes a PR easier to review and merge is:

* Good comments that can be easily processed using YARD.
* Any test results from your fix by running against an actual OpenStack cluster.
This would be best pasted into a **pastebin** like https://pastebin.osuosl.org rather than
the body of the PR.
* Link to images that you used so that the reviewers can test it out too.
