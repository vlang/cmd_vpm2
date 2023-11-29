// Copyright (c) 2019-2023 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module main

import os
import os.cmdline
import rand
import v.help
import v.vmod

struct VCS {
	dir  string        @[required]
	cmd  string        @[required]
	args struct {
		install  string   @[required]
		version  string   @[required] // flag to specify a version, added to install.
		path     string   @[required] // flag to specify a path. E.g., used to explicitly work on a path during multithreaded updating.
		update   string   @[required]
		outdated []string @[required]
	}
}

const settings = init_settings()
const default_vpm_server_urls = ['https://vpm.vlang.io', 'https://vpm.url4e.com']
const vpm_server_urls = rand.shuffle_clone(default_vpm_server_urls) or { [] } // ensure that all queries are distributed fairly
const valid_vpm_commands = ['help', 'search', 'install', 'update', 'upgrade', 'outdated', 'list',
	'remove', 'show']
const excluded_dirs = ['cache', 'vlib']
const supported_vcs = {
	'git': VCS{
		dir: '.git'
		cmd: 'git'
		args: struct {
			install: 'clone --depth=1 --recursive --shallow-submodules'
			version: '--single-branch -b'
			update: 'pull --recurse-submodules' // pulling with `--depth=1` leads to conflicts when the upstream has more than 1 new commits.
			path: '-C'
			outdated: ['fetch', 'rev-parse @', 'rev-parse @{u}']
		}
	}
	'hg':  VCS{
		dir: '.hg'
		cmd: 'hg'
		args: struct {
			install: 'clone'
			version: '' // not supported yet.
			update: 'pull --update'
			path: '-R'
			outdated: ['incoming']
		}
	}
}

fn main() {
	// This tool is intended to be launched by the v frontend,
	// which provides the path to V inside os.getenv('VEXE')
	// args are: vpm [options] SUBCOMMAND module names
	params := cmdline.only_non_options(os.args[1..])
	vpm_log(@FILE_LINE, @FN, 'params: ${params}')
	if params.len < 1 {
		help.print_and_exit('vpm', exit_code: 5)
	}
	vpm_command := params[0]
	mut query := params[1..].clone()
	vpm_log(@FILE_LINE, @FN, 'query: ${query}')
	ensure_vmodules_dir_exist()
	match vpm_command {
		'help' {
			help.print_and_exit('vpm')
		}
		'search' {
			vpm_search(query)
		}
		'install' {
			vpm_install(query)
		}
		'update' {
			vpm_update(query)
		}
		'upgrade' {
			vpm_upgrade()
		}
		'outdated' {
			vpm_outdated()
		}
		'list' {
			vpm_list()
		}
		'remove' {
			vpm_remove(query)
		}
		'show' {
			vpm_show(query)
		}
		else {
			// Unreachable in regular usage. V will catch unknown commands beforehand.
			vpm_error('unknown command "${vpm_command}"')
			help.print_and_exit('vpm', exit_code: 3)
		}
	}
}

fn vpm_upgrade() {
	outdated := get_outdated() or { exit(1) }
	if outdated.len > 0 {
		vpm_update(outdated)
	} else {
		println('Modules are up to date.')
	}
}

fn vpm_outdated() {
	outdated := get_outdated() or { exit(1) }
	if outdated.len > 0 {
		println('Outdated modules:')
		for m in outdated {
			println('  ${m}')
		}
	} else {
		println('Modules are up to date.')
	}
}

fn vpm_list() {
	installed := get_installed_modules()
	if installed.len == 0 {
		println('You have no modules installed.')
		exit(0)
	}
	for m in installed {
		println(m)
	}
}

fn vpm_remove(query []string) {
	if settings.is_help {
		help.print_and_exit('remove')
	}
	if query.len == 0 {
		vpm_error('specify at least one module name for removal.')
		exit(2)
	}
	for m in query {
		final_module_path := get_path_of_existing_module(m) or { continue }
		println('Removing module "${m}" ...')
		vpm_log(@FILE_LINE, @FN, 'removing: ${final_module_path}')
		os.rmdir_all(final_module_path) or { vpm_error(err.msg(), verbose: true) }
		// Delete author directory if it is empty.
		author := m.split('.')[0]
		author_dir := os.real_path(os.join_path(settings.vmodules_path, author))
		if !os.exists(author_dir) {
			continue
		}
		if os.is_dir_empty(author_dir) {
			verbose_println('Removing author folder ${author_dir}')
			os.rmdir(author_dir) or { vpm_error(err.msg(), verbose: true) }
		}
	}
}

fn vpm_show(query []string) {
	installed_modules := get_installed_modules()
	for m in query {
		if m !in installed_modules {
			info := get_mod_vpm_info(m) or { continue }
			print('Name: ${info.name}
Homepage: ${info.url}
Downloads: ${info.nr_downloads}
Installed: False
--------
')
			continue
		}
		path := os.join_path(os.vmodules_dir(), m.replace('.', os.path_separator))
		mod := vmod.from_file(os.join_path(path, 'v.mod')) or { continue }
		print('Name: ${mod.name}
Version: ${mod.version}
Description: ${mod.description}
Homepage: ${mod.repo_url}
Author: ${mod.author}
License: ${mod.license}
Location: ${path}
Requires: ${mod.dependencies.join(', ')}
--------
')
	}
}
