
import core.memory;
import core.exception;
import std.traits;
import core.stdc.string : memset;
import std.conv;
import std.random;
import std.stdio;
import std.datetime;

import pydict;

/*
* This file includes a very fast closed hash map implementation
* based on Pythons dictionary implementation.
* License: Public Domain
*
* Author: Moritz Warning
*
* dmd main.d pydict.d && ./main
*/

void main(char[][] args)
{
	//number of runs
	uint bigN = 3;

	//dictionary size
	uint dictSize = 2_000_000;

	//GC.disable();

	testLinear(bigN, dictSize);
}

uint rand()
{
	return uniform(uint.min, uint.max);
}

void testLinear(uint M, uint N)
{
	double lookup_time = 0;
	double insert_time = 0;

	writef("Testing linear access %s\n", PyDict!(char[], uint).stringof);

	//for string testing
	char[][] strings = new char[][N];
	for(uint i; i < N; ++i)
	{
		strings[i] = "key_" ~ to!(char[])(i);
	}

	void run(ulong ix)
	{
		StopWatch sw;

		auto aa = new PyDict!(char[], uint)();

		//populate PyDict
		for(uint i = N ; i--;)
		{
			aa[strings[i]] = 0;
		}

		sw.start();
		for(uint i=N; i--;)
		{
			auto foo = (strings[i] in aa);
		}
		sw.stop();
	
		writeln("Time elapsed: ", sw.peek().hnsecs, " hnsecs");
	}

	for(auto i = 0; i < M; i++)
	{
		run(i);
	}

	writefln("%u x %u iterations", M, N);
	writefln("inserts:  %u/s (%fs)", cast(uint) (M * N / insert_time), (insert_time / M));
	writefln("lookups: %u/s (%fs)", cast(uint) (M * N / lookup_time), (lookup_time / M));
}
