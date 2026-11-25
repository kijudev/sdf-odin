package game

import "../../libs/ecs"

Kind :: enum {
	// parts
	Camera,
	Transform,
	Shape,
	Light,
	Animation,

	// stashes
	Window,
	Time,
	Events,
	Renderer,
}

Stage :: enum {
	Input,
	Update,
	Render,
}

World :: ecs.World(Kind, Stage)
Stuff :: ecs.Stuff(Kind, Stage)
Query :: ecs.Query(Kind, Stage)
Thing :: ecs.Thing

THING_NIL :: ecs.THING_NIL
